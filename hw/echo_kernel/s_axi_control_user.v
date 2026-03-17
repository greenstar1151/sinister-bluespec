`timescale 1ns / 1ps

module s_axi_control_user #(
    parameter integer C_S_AXI_ADDR_WIDTH = 12,
    parameter integer C_S_AXI_DATA_WIDTH = 32
) (
    input  wire                          ACLK,
    input  wire                          ARESET_N,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] AWADDR,
    input  wire                          AWVALID,
    output wire                          AWREADY,
    input  wire [C_S_AXI_DATA_WIDTH-1:0] WDATA,
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0] WSTRB,
    input  wire                          WVALID,
    output wire                          WREADY,
    output wire [1:0]                    BRESP,
    output wire                          BVALID,
    input  wire                          BREADY,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] ARADDR,
    input  wire                          ARVALID,
    output wire                          ARREADY,
    output wire [C_S_AXI_DATA_WIDTH-1:0] RDATA,
    output wire [1:0]                    RRESP,
    output wire                          RVALID,
    input  wire                          RREADY,
    output wire                          interrupt,
    output wire [31:0]                   echo_in,
    output wire                          echo_write_pulse,
    output wire                          counter_read_pulse,
    input  wire [31:0]                   echo_out,
    input  wire [31:0]                   counter,
    input  wire [31:0]                   status,
    input  wire [31:0]                   magic
);

localparam [5:0] ADDR_ECHO_IN  = 6'h00;
localparam [5:0] ADDR_ECHO_OUT = 6'h04;
localparam [5:0] ADDR_COUNTER  = 6'h08;
localparam [5:0] ADDR_MAGIC    = 6'h0c;
localparam [5:0] ADDR_STATUS   = 6'h10;

localparam [1:0] WRIDLE = 2'd0;
localparam [1:0] WRDATA = 2'd1;
localparam [1:0] WRRESP = 2'd2;
localparam [1:0] WRRESET = 2'd3;

localparam [1:0] RDIDLE = 2'd0;
localparam [1:0] RDDATA = 2'd1;
localparam [1:0] RDRESET = 2'd2;

localparam integer ADDR_BITS = 6;

reg [1:0] wstate = WRRESET;
reg [1:0] rstate = RDRESET;
reg [1:0] wnext;
reg [1:0] rnext;
reg [ADDR_BITS-1:0] waddr;
reg [31:0] rdata;
reg [31:0] int_echo_in;
reg int_echo_write_pulse;
reg int_counter_read_pulse;

wire ACLK_EN;
wire ARESET;
wire aw_hs;
wire w_hs;
wire ar_hs;
wire [31:0] wmask;
wire [ADDR_BITS-1:0] raddr;

assign ACLK_EN = 1'b1;
assign ARESET = ~ARESET_N;

assign AWREADY = (wstate == WRIDLE);
assign WREADY  = (wstate == WRDATA);
assign BRESP   = 2'b00;
assign BVALID  = (wstate == WRRESP);
assign aw_hs   = AWVALID & AWREADY;
assign w_hs    = WVALID & WREADY;
assign wmask   = {{8{WSTRB[3]}}, {8{WSTRB[2]}}, {8{WSTRB[1]}}, {8{WSTRB[0]}}};

assign ARREADY = (rstate == RDIDLE);
assign RVALID  = (rstate == RDDATA);
assign RRESP   = 2'b00;
assign RDATA   = rdata;
assign ar_hs   = ARVALID & ARREADY;
assign raddr   = ARADDR[ADDR_BITS-1:0];

assign interrupt = 1'b0;
assign echo_in = int_echo_in;
assign echo_write_pulse = int_echo_write_pulse;
assign counter_read_pulse = int_counter_read_pulse;

always @(posedge ACLK) begin
    if (ARESET)
        wstate <= WRRESET;
    else if (ACLK_EN)
        wstate <= wnext;
end

always @(*) begin
    case (wstate)
        WRIDLE:  wnext = AWVALID ? WRDATA : WRIDLE;
        WRDATA:  wnext = WVALID ? WRRESP : WRDATA;
        WRRESP:  wnext = BREADY ? WRIDLE : WRRESP;
        default: wnext = WRIDLE;
    endcase
end

always @(posedge ACLK) begin
    if (ACLK_EN && aw_hs)
        waddr <= AWADDR[ADDR_BITS-1:0];
end

always @(posedge ACLK) begin
    if (ARESET)
        rstate <= RDRESET;
    else if (ACLK_EN)
        rstate <= rnext;
end

always @(*) begin
    case (rstate)
        RDIDLE:  rnext = ARVALID ? RDDATA : RDIDLE;
        RDDATA:  rnext = (RREADY & RVALID) ? RDIDLE : RDDATA;
        default: rnext = RDIDLE;
    endcase
end

always @(posedge ACLK) begin
    if (ARESET) begin
        int_echo_in <= 32'd0;
        int_echo_write_pulse <= 1'b0;
        int_counter_read_pulse <= 1'b0;
    end else if (ACLK_EN) begin
        int_echo_write_pulse <= 1'b0;
        int_counter_read_pulse <= 1'b0;

        if (w_hs && waddr == ADDR_ECHO_IN)
            int_echo_in <= (WDATA & wmask) | (int_echo_in & ~wmask);

        if (w_hs && waddr == ADDR_ECHO_IN)
            int_echo_write_pulse <= 1'b1;

        if (ar_hs && raddr == ADDR_COUNTER)
            int_counter_read_pulse <= 1'b1;
    end
end

always @(posedge ACLK) begin
    if (ARESET) begin
        rdata <= 32'd0;
    end else if (ACLK_EN && ar_hs) begin
        case (raddr)
            ADDR_ECHO_IN:  rdata <= int_echo_in;
            ADDR_ECHO_OUT: rdata <= echo_out;
            ADDR_COUNTER:  rdata <= counter;
            ADDR_MAGIC:    rdata <= magic;
            ADDR_STATUS:   rdata <= status;
            default:       rdata <= 32'd0;
        endcase
    end
end

endmodule