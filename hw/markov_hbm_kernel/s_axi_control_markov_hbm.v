`timescale 1ns / 1ps

module s_axi_control_markov_hbm #(
    parameter integer C_S_AXI_ADDR_WIDTH = 12,
    parameter integer C_S_AXI_DATA_WIDTH = 32
) (
    input  wire                          ACLK,
    input  wire                          ARESET_N,

    // AXI4-Lite Write Address
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] AWADDR,
    input  wire                          AWVALID,
    output wire                          AWREADY,
    // AXI4-Lite Write Data
    input  wire [C_S_AXI_DATA_WIDTH-1:0] WDATA,
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0] WSTRB,
    input  wire                          WVALID,
    output wire                          WREADY,
    // AXI4-Lite Write Response
    output wire [1:0]                    BRESP,
    output wire                          BVALID,
    input  wire                          BREADY,
    // AXI4-Lite Read Address
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] ARADDR,
    input  wire                          ARVALID,
    output wire                          ARREADY,
    // AXI4-Lite Read Data
    output wire [C_S_AXI_DATA_WIDTH-1:0] RDATA,
    output wire [1:0]                    RRESP,
    output wire                          RVALID,
    input  wire                          RREADY,

    // Interrupt (unused)
    output wire                          interrupt,

    // --- BSV-facing ports ---
    // Command register
    output wire [31:0]                   command,
    output wire                          command_write_pulse,
    // HBM DNA pointer (64-bit)
    output wire [31:0]                   dna_ptr_lo,
    output wire [31:0]                   dna_ptr_hi,
    // Number of DNA entries to read
    output wire [31:0]                   num_entries,

    // Status (from BSV)
    input  wire [31:0]                   status,
    // Total bases processed (from BSV)
    input  wire [31:0]                   total_bases,
    // Magic constant
    input  wire [31:0]                   magic,
    // Cycle counter (64-bit, from BSV)
    input  wire [31:0]                   cycle_lo,
    input  wire [31:0]                   cycle_hi,

    // Base probabilities Q16.16 (4 values, from BSV)
    input  wire [31:0]                   base_prob_0,
    input  wire [31:0]                   base_prob_1,
    input  wire [31:0]                   base_prob_2,
    input  wire [31:0]                   base_prob_3,

    // Transition probability read interface (256 values via indexed access)
    output wire [7:0]                    trans_prob_raddr,
    output wire                          trans_prob_ren,
    input  wire [31:0]                   trans_prob_rdata
);

// ============================================================
// Register address map
// ============================================================
// 0x000: COMMAND      (W)   — 0x01=reset, 0x02=start (HBM read + train + normalize)
// 0x004: STATUS       (R)   — 0=idle, 1=reading+training, 2=normalizing, 3=done
// 0x008: TOTAL_BASES  (R)
// 0x00C: MAGIC        (R)
// 0x010: CYCLE_LO     (R)
// 0x014: CYCLE_HI     (R)
// 0x018: DNA_PTR_LO   (W)  — HBM address low 32 bits
// 0x01C: DNA_PTR_HI   (W)  — HBM address high 32 bits
// 0x020: NUM_ENTRIES   (W)  — number of DNA entries (bytes) to read
// 0x100: BASE_PROB[0..3] (R)  Q16.16
// 0x200-0x5FC: TRANS_PROB[0..255] (R) Q16.16

localparam [1:0] WRIDLE  = 2'd0;
localparam [1:0] WRDATA  = 2'd1;
localparam [1:0] WRRESP  = 2'd2;
localparam [1:0] WRRESET = 2'd3;

localparam [1:0] RDIDLE  = 2'd0;
localparam [1:0] RDDATA  = 2'd1;
localparam [1:0] RDWAIT  = 2'd2;
localparam [1:0] RDRESET = 2'd3;

reg [1:0] wstate = WRRESET;
reg [1:0] rstate = RDRESET;
reg [1:0] wnext;
reg [1:0] rnext;
reg [C_S_AXI_ADDR_WIDTH-1:0] waddr;
reg [31:0] rdata_reg;

// Internal write-side registers
reg [31:0] int_command;
reg        int_command_write_pulse;
reg [31:0] int_dna_ptr_lo;
reg [31:0] int_dna_ptr_hi;
reg [31:0] int_num_entries;

// Read pipeline for trans_prob
reg [7:0]  int_trans_prob_raddr;
reg        int_trans_prob_ren;
reg        rd_is_trans_prob;

wire ARESET = ~ARESET_N;

wire aw_hs = AWVALID & AWREADY;
wire w_hs  = WVALID  & WREADY;
wire ar_hs = ARVALID & ARREADY;
wire [31:0] wmask = {{8{WSTRB[3]}}, {8{WSTRB[2]}}, {8{WSTRB[1]}}, {8{WSTRB[0]}}};
wire [C_S_AXI_ADDR_WIDTH-1:0] raddr = ARADDR;

// Write channel
assign AWREADY = (wstate == WRIDLE);
assign WREADY  = (wstate == WRDATA);
assign BRESP   = 2'b00;
assign BVALID  = (wstate == WRRESP);

// Read channel
assign ARREADY = (rstate == RDIDLE);
assign RVALID  = (rstate == RDDATA);
assign RRESP   = 2'b00;
assign RDATA   = rdata_reg;

assign interrupt = 1'b0;
assign command = int_command;
assign command_write_pulse = int_command_write_pulse;
assign dna_ptr_lo = int_dna_ptr_lo;
assign dna_ptr_hi = int_dna_ptr_hi;
assign num_entries = int_num_entries;
assign trans_prob_raddr = int_trans_prob_raddr;
assign trans_prob_ren = int_trans_prob_ren;

// ============================================================
// Write FSM
// ============================================================
always @(posedge ACLK) begin
    if (ARESET)
        wstate <= WRRESET;
    else
        wstate <= wnext;
end

always @(*) begin
    case (wstate)
        WRIDLE:  wnext = AWVALID ? WRDATA : WRIDLE;
        WRDATA:  wnext = WVALID  ? WRRESP : WRDATA;
        WRRESP:  wnext = BREADY  ? WRIDLE : WRRESP;
        default: wnext = WRIDLE;
    endcase
end

always @(posedge ACLK) begin
    if (aw_hs)
        waddr <= AWADDR;
end

// Write data handling
always @(posedge ACLK) begin
    if (ARESET) begin
        int_command <= 32'd0;
        int_command_write_pulse <= 1'b0;
        int_dna_ptr_lo <= 32'd0;
        int_dna_ptr_hi <= 32'd0;
        int_num_entries <= 32'd0;
    end else begin
        int_command_write_pulse <= 1'b0;

        if (w_hs) begin
            case (waddr[11:0])
                12'h000: begin // COMMAND
                    int_command <= (WDATA & wmask) | (int_command & ~wmask);
                    int_command_write_pulse <= 1'b1;
                end
                12'h018: begin // DNA_PTR_LO
                    int_dna_ptr_lo <= (WDATA & wmask) | (int_dna_ptr_lo & ~wmask);
                end
                12'h01C: begin // DNA_PTR_HI
                    int_dna_ptr_hi <= (WDATA & wmask) | (int_dna_ptr_hi & ~wmask);
                end
                12'h020: begin // NUM_ENTRIES
                    int_num_entries <= (WDATA & wmask) | (int_num_entries & ~wmask);
                end
                default: ;
            endcase
        end
    end
end

// ============================================================
// Read FSM
// ============================================================
always @(posedge ACLK) begin
    if (ARESET)
        rstate <= RDRESET;
    else
        rstate <= rnext;
end

always @(*) begin
    case (rstate)
        RDIDLE:  rnext = ARVALID ? (((ARADDR >= 12'h200) && (ARADDR < 12'h600)) ? RDWAIT : RDDATA) : RDIDLE;
        RDWAIT:  rnext = RDDATA;  // 1-cycle latency for trans_prob lookup
        RDDATA:  rnext = (RREADY & RVALID) ? RDIDLE : RDDATA;
        default: rnext = RDIDLE;
    endcase
end

// Issue trans_prob read address when entering RDWAIT
always @(posedge ACLK) begin
    if (ARESET) begin
        int_trans_prob_ren <= 1'b0;
        int_trans_prob_raddr <= 8'd0;
        rd_is_trans_prob <= 1'b0;
    end else begin
        int_trans_prob_ren <= 1'b0;
        if (ar_hs && (ARADDR >= 12'h200) && (ARADDR < 12'h600)) begin
            int_trans_prob_raddr <= (ARADDR - 12'h200) >> 2;
            int_trans_prob_ren <= 1'b1;
            rd_is_trans_prob <= 1'b1;
        end else if (ar_hs) begin
            rd_is_trans_prob <= 1'b0;
        end
    end
end

// Read data mux
always @(posedge ACLK) begin
    if (ARESET) begin
        rdata_reg <= 32'd0;
    end else if (rstate == RDWAIT) begin
        rdata_reg <= trans_prob_rdata;
    end else if (ar_hs && !((ARADDR >= 12'h200) && (ARADDR < 12'h600))) begin
        case (ARADDR[11:0])
            12'h000: rdata_reg <= int_command;
            12'h004: rdata_reg <= status;
            12'h008: rdata_reg <= total_bases;
            12'h00C: rdata_reg <= magic;
            12'h010: rdata_reg <= cycle_lo;
            12'h014: rdata_reg <= cycle_hi;
            12'h018: rdata_reg <= int_dna_ptr_lo;
            12'h01C: rdata_reg <= int_dna_ptr_hi;
            12'h020: rdata_reg <= int_num_entries;
            12'h100: rdata_reg <= base_prob_0;
            12'h104: rdata_reg <= base_prob_1;
            12'h108: rdata_reg <= base_prob_2;
            12'h10C: rdata_reg <= base_prob_3;
            default: rdata_reg <= 32'd0;
        endcase
    end
end

endmodule
