// hid-desc-check: the raw GET_DESCRIPTOR replies of the gadget's HID interface, as a
// head unit sees them. Run it on a Linux PC with the Pi's USB-C port plugged in and the
// ipod client running on the Pi (the gadget only connects while /dev/iap0 is open):
//
//   gcc -O2 -o hid-desc-check tools/hid-desc-check.c
//   lsusb -d 05ac:                      # Bus BBB Device DDD
//   echo 2 | sudo tee /sys/bus/usb/devices/<port>/bConfigurationValue   # the iPod config
//   sudo ./hid-desc-check /dev/bus/usb/BBB/DDD 2 21:9 21:255 22:96 22:160 22:2165
//
// Expected (what the Clarion X9U6 in a 2014 Infiniti Q60 needs, doc/q60-notes.md): every
// reply is exactly wLength bytes long and starts with the report descriptor, also for 0x21
// (with the default descriptor its 9 bytes, 06 00 ff 09 01 a1 01 75 08, claim a 0x0875-byte
// report descriptor, which the head unit then asks for). A reply shorter than wLength is
// the regression that broke the Q60. Prints the replies, then PASS (exit 0) or FAIL (exit 1).
//
#include <fcntl.h>
#include <linux/usbdevice_fs.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	if (argc < 4) {
		fprintf(stderr, "usage: %s /dev/bus/usb/BBB/DDD intf type:wLength...\n", argv[0]);
		return 2;
	}
	int fd = open(argv[1], O_RDWR);
	if (fd < 0) { perror("open"); return 1; }
	unsigned int intf = atoi(argv[2]);
	struct usbdevfs_ioctl disc = { .ifno = intf, .ioctl_code = USBDEVFS_DISCONNECT, .data = NULL };
	ioctl(fd, USBDEVFS_IOCTL, &disc);	/* no driver bound is fine */
	if (ioctl(fd, USBDEVFS_CLAIMINTERFACE, &intf) < 0) { perror("claim"); return 1; }

	static const unsigned char default_start[9] = { 0x06, 0x00, 0xff, 0x09, 0x01, 0xa1, 0x01, 0x75, 0x08 };
	static unsigned char buf[4096], first[9];
	int nfirst = -1, failed = 0, is_default = 1;
	for (int i = 3; i < argc; i++) {
		unsigned int type, len;
		if (sscanf(argv[i], "%x:%u", &type, &len) != 2 || len > sizeof(buf)) {
			fprintf(stderr, "bad request %s\n", argv[i]);
			return 2;
		}
		memset(buf, 0xee, sizeof(buf));
		struct usbdevfs_ctrltransfer ct = {
			.bRequestType = 0x81,	/* device to host, standard, interface */
			.bRequest = 0x06,	/* GET_DESCRIPTOR */
			.wValue = type << 8,
			.wIndex = intf,
			.wLength = len,
			.timeout = 1000,
			.data = buf,
		};
		int n = ioctl(fd, USBDEVFS_CONTROL, &ct);
		printf("0x%02x wLength %u -> ", type, len);
		if (n < 0) {
			perror("control");
			failed++;
			continue;
		}
		printf("%d bytes:", n);
		for (int k = 0; k < n; k++)
			printf(" %02x", buf[k]);
		printf("\n");

		int k = n < 9 ? n : 9;
		if ((unsigned int)n != len) {
			printf("  FAIL: %d bytes, not wLength (%u)\n", n, len);
			failed++;
		}
		if (nfirst < 0) {
			nfirst = k;
			memcpy(first, buf, k);
		} else if (memcmp(first, buf, k < nfirst ? k : nfirst)) {
			printf("  FAIL: does not start like the first reply\n");
			failed++;
		}
		if (memcmp(buf, default_start, k))
			is_default = 0;
	}
	if (nfirst >= 0)
		printf("starts like the default descriptor: %s\n", is_default ? "yes" : "no");
	printf("%s\n", failed ? "FAIL" : "PASS");
	return failed ? 1 : 0;
}
