/* pnal_config.h — Platform Network Abstraction Layer config for Linux (CCLRTE)
 * Required by pnet_api.h. Defines Ethernet type constants used by p-net stack.
 */
#ifndef PNAL_CONFIG_H
#define PNAL_CONFIG_H

/* Standard Ethernet type values */
#define PNAL_ETHTYPE_ALL      0x0000U  /* Match all frame types (raw socket) */
#define PNAL_ETHTYPE_IP       0x0800U
#define PNAL_ETHTYPE_ARP      0x0806U
#define PNAL_ETHTYPE_VLAN     0x8100U
#define PNAL_ETHTYPE_PROFINET 0x8892U
#define PNAL_ETHTYPE_LLDP     0x88CCU

#endif /* PNAL_CONFIG_H */
