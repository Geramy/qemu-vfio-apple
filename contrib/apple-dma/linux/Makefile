# Out-of-tree build against running (or specified) kernel.
# Usage:
#   make -C /lib/modules/$(uname -r)/build M=$(pwd) modules
# or:
#   make KERNELDIR=/path/to/linux/build

KERNELDIR ?= /lib/modules/$(shell uname -r)/build

obj-m += apple_dma.o
apple_dma-y := apple_dma_main.o apple_dma_trace.o \
	quirks/dczid_patch.o quirks/tso_patch.o quirks/uvm_page_patch.o

all:
	$(MAKE) -C $(KERNELDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KERNELDIR) M=$(CURDIR) clean

install:
	install -d $(DESTDIR)/lib/modules/$(shell uname -r)/extra
	install -m 644 apple_dma.ko \
		$(DESTDIR)/lib/modules/$(shell uname -r)/extra/
	install -d $(DESTDIR)/etc/modprobe.d
	install -d $(DESTDIR)/etc/modules-load.d
	install -m 644 apple-dma-options.conf \
		$(DESTDIR)/etc/modprobe.d/
	install -m 644 apple-dma-load.conf \
		$(DESTDIR)/etc/modules-load.d/
	depmod -a
	update-initramfs -u
	rmmod apple_dma || true
	modprobe apple_dma

uninstall:
	rm -f $(DESTDIR)/lib/modules/$(shell uname -r)/extra/apple_dma.ko
	rm -f $(DESTDIR)/etc/modprobe.d/apple-dma-options.conf
	rm -f $(DESTDIR)/etc/modules-load.d/apple-dma-load.conf
	depmod -a
	update-initramfs -u
	rmmod apple_dma || true

.PHONY: all clean install uninstall
