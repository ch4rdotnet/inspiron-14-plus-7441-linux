# out-of-tree copy of qcom-camss with phy= and lane*= parameters, see README.md
include Makefile.objs
KDIR ?= /lib/modules/$(shell uname -r)/build
all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules
clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
