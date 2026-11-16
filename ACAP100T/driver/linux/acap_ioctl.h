#ifndef ACAP_IOCTL_LINUX_H
#define ACAP_IOCTL_LINUX_H

#include <linux/ioctl.h>
#include "acap_uapi.h"

#define ACAP_IOC_GET_INFO       _IOR('A', 0x01, struct acap_info)
#define ACAP_IOC_START          _IO('A', 0x02)
#define ACAP_IOC_STOP           _IO('A', 0x03)
#define ACAP_IOC_WAIT_FRAME     _IOWR('A', 0x04, struct acap_frame)
#define ACAP_IOC_RELEASE_FRAME  _IOW('A', 0x05, acap_u32)

#endif
