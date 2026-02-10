LIBPATH=../../libs/bluespecpcie
BLIBPATH=../../libs/bluelib/src/
BUILDTOOLS=$(LIBPATH)/buildtools/

CUSTOMBSV= -p +:$(LIBPATH)/src/:$(LIBPATH)/dram/src:$(BLIBPATH)/:$(BLIBPATH)/msfp/
CUSTOMCPP_BSIM= $(BLIBPATH)/bdpi.cpp

include $(BUILDTOOLS)/Makefile.base
