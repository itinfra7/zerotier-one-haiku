from pathlib import Path
import re
import sys

build_root = Path(sys.argv[1])

def replace_once(text, old, new, label):
    if new and new in text:
        return text
    if old not in text:
        raise SystemExit(f"unable to apply {label}")
    return text.replace(old, new, 1)

one_path = build_root / "service" / "OneService.cpp"
one_text = one_path.read_text()
one_old = """#ifdef __HAIKU__
\t\t\tif (n.tap() && (n.tap()->deviceName().compare(0, 4, "tap/") == 0)) {
\t\t\t\tInetAddress preferredV6;
\t\t\t\tfor (std::vector<InetAddress>::const_iterator ip(newManagedIps.begin()); ip != newManagedIps.end(); ++ip) {
\t\t\t\t\tif (ip->isV6() && ((! preferredV6) || (ip->netmaskBits() > preferredV6.netmaskBits()))) {
\t\t\t\t\t\tpreferredV6 = *ip;
\t\t\t\t\t}
\t\t\t\t}
\t\t\t\tif (preferredV6) {
\t\t\t\t\tnewManagedIps.erase(
\t\t\t\t\t\tstd::remove_if(
\t\t\t\t\t\t\tnewManagedIps.begin(),
\t\t\t\t\t\t\tnewManagedIps.end(),
\t\t\t\t\t\t\t[preferredV6](const InetAddress& candidate) {
\t\t\t\t\t\t\t\treturn candidate.isV6() && (candidate != preferredV6);
\t\t\t\t\t\t\t}),
\t\t\t\t\t\tnewManagedIps.end());
\t\t\t\t}
\t\t\t}
#endif

"""
if "preferredV6" in one_text:
    one_text = replace_once(one_text, one_old, "", "OneService hotfix")
    one_path.write_text(one_text)

hpp_path = build_root / "osdep" / "BSDEthernetTap.hpp"
hpp_text = hpp_path.read_text()
hpp_old = """\t\tstd::vector<InetAddress> _haikuLocalV6Ips;\n"""
hpp_new = """\t\tstd::vector<InetAddress> _haikuLocalV6Ips;\n\t\tstd::vector<InetAddress> _haikuManagedV6Ips;\n"""
if "_haikuManagedV6Ips" not in hpp_text:
    hpp_text = replace_once(hpp_text, hpp_old, hpp_new, "BSDEthernetTap.hpp hotfix")
    hpp_path.write_text(hpp_text)

bsd_path = build_root / "osdep" / "BSDEthernetTap.cpp"
bsd_text = bsd_path.read_text()
if "___haikuAdjustIpv6OnLinkRoute" not in bsd_text:
    bsd_anchor_old = """\t\tfprintf(stderr, \"HAIKU TAP ROUTE dev=%s net=%s/%s exit=%d\" ZT_EOL_S, dev.c_str(), network, prefixLen, exitcode);\n\t\tfflush(stderr);\n\t}\n}\n\nstatic void ___haikuEnsureIpv6MulticastRoutes(const std::string& dev)\n{"""
    bsd_anchor_new = """\t\tfprintf(stderr, \"HAIKU TAP ROUTE dev=%s net=%s/%s exit=%d\" ZT_EOL_S, dev.c_str(), network, prefixLen, exitcode);\n\t\tfflush(stderr);\n\t}\n}\n\nstatic void ___haikuAdjustIpv6OnLinkRoute(const char* op, const std::string& dev, const InetAddress& ip)\n{\n\tif ((! ip.isV6()) || (! ip.netmaskBits()))\n\t\treturn;\n\n\tInetAddress network = ip.network();\n\tchar networkBuf[128];\n\tchar prefixBuf[8];\n\tOSUtils::ztsnprintf(prefixBuf, sizeof(prefixBuf), \"%u\", ip.netmaskBits());\n\n\tlong cpid = (long)vfork();\n\tif (cpid == 0) {\n\t\t::execlp(\"route\", \"route\", op, dev.c_str(), \"inet6\", network.toIpString(networkBuf), \"prefixlen\", prefixBuf, (const char*)0);\n\t\t::_exit(-1);\n\t}\n\telse if (cpid > 0) {\n\t\tint exitcode = -1;\n\t\t::waitpid(cpid, &exitcode, 0);\n\t\tfprintf(stderr, \"HAIKU TAP ROUTE dev=%s op=%s net=%s/%s exit=%d\" ZT_EOL_S, dev.c_str(), op, network.toIpString(networkBuf), prefixBuf, exitcode);\n\t\tfflush(stderr);\n\t}\n}\n\nstatic void ___haikuEnsureIpv6MulticastRoutes(const std::string& dev)\n{"""
    bsd_text = replace_once(bsd_text, bsd_anchor_old, bsd_anchor_new, "BSDEthernetTap route helper")

if "___haikuReconcileIpv6Routes" not in bsd_text:
    reconcile_anchor_old = """static void ___haikuEnsureIpv6MulticastRoutes(const std::string& dev)\n{\n\t// Haiku does not auto-install the multicast routes needed for IPv6 ND on tap devices.\n\t// Without these, on-link IPv6 traffic fails with ENETUNREACH before any packet is emitted.\n\t___haikuEnsureIpv6MulticastRoute(dev, \"ff00::\", \"8\");\n\t___haikuEnsureIpv6MulticastRoute(dev, \"ff02::\", \"16\");\n}\n"""
    reconcile_anchor_new = """static void ___haikuEnsureIpv6MulticastRoutes(const std::string& dev)\n{\n\t// Haiku does not auto-install the multicast routes needed for IPv6 ND on tap devices.\n\t// Without these, on-link IPv6 traffic fails with ENETUNREACH before any packet is emitted.\n\t___haikuEnsureIpv6MulticastRoute(dev, \"ff00::\", \"8\");\n\t___haikuEnsureIpv6MulticastRoute(dev, \"ff02::\", \"16\");\n}\n\nstatic void ___haikuReconcileIpv6Routes(const std::string& dev, const std::vector<InetAddress>& ips)\n{\n\tfor (std::vector<InetAddress>::const_iterator ip(ips.begin()); ip != ips.end(); ++ip) {\n\t\t___haikuAdjustIpv6OnLinkRoute(\"add\", dev, *ip);\n\t}\n\t___haikuEnsureIpv6MulticastRoutes(dev);\n}\n"""
    bsd_text = replace_once(bsd_text, reconcile_anchor_old, reconcile_anchor_new, "BSDEthernetTap route reconcile helper")

if "_haikuManagedV6Ips.push_back(ip);" not in bsd_text:
    bsd_add_old = """\t\t\t\t\tif (haikuTap) {\n\t\t\t\t\t\t___haikuEnsureIpv6MulticastRoutes(_dev);\n\t\t\t\t\t}\n"""
    bsd_add_new = """\t\t\t\t\tif (haikuTap) {\n\t\t\t\t\t\t_haikuManagedV6Ips.erase(\n\t\t\t\t\t\t\tstd::remove_if(\n\t\t\t\t\t\t\t\t_haikuManagedV6Ips.begin(),\n\t\t\t\t\t\t\t\t_haikuManagedV6Ips.end(),\n\t\t\t\t\t\t\t\t[ip](const InetAddress& candidate) {\n\t\t\t\t\t\t\t\t\treturn candidate.ipOnly() == ip.ipOnly();\n\t\t\t\t\t\t\t\t}),\n\t\t\t\t\t\t\t_haikuManagedV6Ips.end());\n\t\t\t\t\t\t_haikuManagedV6Ips.push_back(ip);\n\t\t\t\t\t\t___haikuReconcileIpv6Routes(_dev, _haikuManagedV6Ips);\n\t\t\t\t\t}\n"""
    bsd_text = replace_once(bsd_text, bsd_add_old, bsd_add_new, "BSDEthernetTap addIp hotfix")

if "___haikuReconcileIpv6Routes(_dev, _haikuManagedV6Ips);" not in bsd_text:
    raise SystemExit("failed to apply BSDEthernetTap addIp reconcile hotfix")

if "_haikuManagedV6Ips.erase(" not in bsd_text:
    bsd_del_old = """\t\t\telse if (ip.isV6()) {\n\t\t\t\t_haikuLocalV6Ips.erase(std::remove(_haikuLocalV6Ips.begin(), _haikuLocalV6Ips.end(), ip.ipOnly()), _haikuLocalV6Ips.end());\n\t\t\t}\n"""
    bsd_del_new = """\t\t\telse if (ip.isV6()) {\n\t\t\t\t_haikuLocalV6Ips.erase(std::remove(_haikuLocalV6Ips.begin(), _haikuLocalV6Ips.end(), ip.ipOnly()), _haikuLocalV6Ips.end());\n\t\t\t\tif (_dev.compare(0, 4, \"tap/\") == 0) {\n\t\t\t\t\t_haikuManagedV6Ips.erase(\n\t\t\t\t\t\tstd::remove_if(\n\t\t\t\t\t\t\t_haikuManagedV6Ips.begin(),\n\t\t\t\t\t\t\t_haikuManagedV6Ips.end(),\n\t\t\t\t\t\t\t[ip](const InetAddress& candidate) {\n\t\t\t\t\t\t\t\treturn candidate.ipOnly() == ip.ipOnly();\n\t\t\t\t\t\t\t}),\n\t\t\t\t\t\t_haikuManagedV6Ips.end());\n\t\t\t\t\t___haikuAdjustIpv6OnLinkRoute(\"delete\", _dev, ip);\n\t\t\t\t\t___haikuReconcileIpv6Routes(_dev, _haikuManagedV6Ips);\n\t\t\t\t}\n\t\t\t}\n"""
    bsd_text = replace_once(bsd_text, bsd_del_old, bsd_del_new, "BSDEthernetTap removeIp hotfix")

if "_haikuManagedV6Ips.erase(" not in bsd_text:
    raise SystemExit("failed to apply BSDEthernetTap removeIp reconcile hotfix")

if "___haikuFindTapBySourceV6" not in bsd_text:
    reroute_anchor_old = """static const ZeroTier::MAC ___broadcastMac((uint64_t)0xffffffffffffULL);\n"""
    reroute_anchor_new = """static const ZeroTier::MAC ___broadcastMac((uint64_t)0xffffffffffffULL);\nstatic Mutex ___haikuV6OwnerLock;\nstatic std::map<std::string,BSDEthernetTap*> ___haikuTapByV6Source;\n\nstatic inline std::string ___haikuV6SourceKey(const void* raw)\n{\n\treturn std::string(reinterpret_cast<const char*>(raw), 16);\n}\n\nstatic void ___haikuRegisterTapSourceV6(BSDEthernetTap* tap,const InetAddress& ip)\n{\n\tif ((! tap) || (! ip.isV6()))\n\t\treturn;\n\tMutex::Lock _l(___haikuV6OwnerLock);\n\t___haikuTapByV6Source[___haikuV6SourceKey(ip.rawIpData())] = tap;\n}\n\nstatic void ___haikuUnregisterTapSourceV6(BSDEthernetTap* tap,const InetAddress& ip)\n{\n\tif ((! tap) || (! ip.isV6()))\n\t\treturn;\n\tMutex::Lock _l(___haikuV6OwnerLock);\n\tstd::map<std::string,BSDEthernetTap*>::iterator it = ___haikuTapByV6Source.find(___haikuV6SourceKey(ip.rawIpData()));\n\tif ((it != ___haikuTapByV6Source.end()) && (it->second == tap)) {\n\t\t___haikuTapByV6Source.erase(it);\n\t}\n}\n\nstatic void ___haikuUnregisterTapSources(BSDEthernetTap* tap)\n{\n\tif (! tap)\n\t\treturn;\n\tMutex::Lock _l(___haikuV6OwnerLock);\n\tfor (std::map<std::string,BSDEthernetTap*>::iterator it = ___haikuTapByV6Source.begin(); it != ___haikuTapByV6Source.end();) {\n\t\tif (it->second == tap) {\n\t\t\tit = ___haikuTapByV6Source.erase(it);\n\t\t}\n\t\telse {\n\t\t\t++it;\n\t\t}\n\t}\n}\n\nstatic BSDEthernetTap* ___haikuFindTapBySourceV6(const void* raw)\n{\n\tMutex::Lock _l(___haikuV6OwnerLock);\n\tstd::map<std::string,BSDEthernetTap*>::const_iterator it = ___haikuTapByV6Source.find(___haikuV6SourceKey(raw));\n\treturn (it == ___haikuTapByV6Source.end()) ? (BSDEthernetTap*)0 : it->second;\n}\n"""
    bsd_text = replace_once(bsd_text, reroute_anchor_old, reroute_anchor_new, "BSDEthernetTap IPv6 source owner registry")

if "___haikuUnregisterTapSources(this);" not in bsd_text:
    destructor_old = """BSDEthernetTap::~BSDEthernetTap()\n{\n"""
    destructor_new = """BSDEthernetTap::~BSDEthernetTap()\n{\n#ifdef __HAIKU__\n\t___haikuUnregisterTapSources(this);\n#endif\n"""
    bsd_text = replace_once(bsd_text, destructor_old, destructor_new, "BSDEthernetTap destructor hotfix")

if "___haikuRegisterTapSourceV6(this, ip.ipOnly());" not in bsd_text:
    register_old = """\t\t\t\t\t_haikuLocalV6Ips.erase(std::remove(_haikuLocalV6Ips.begin(), _haikuLocalV6Ips.end(), ip.ipOnly()), _haikuLocalV6Ips.end());\n\t\t\t\t\t_haikuLocalV6Ips.push_back(ip.ipOnly());\n"""
    register_new = """\t\t\t\t\t_haikuLocalV6Ips.erase(std::remove(_haikuLocalV6Ips.begin(), _haikuLocalV6Ips.end(), ip.ipOnly()), _haikuLocalV6Ips.end());\n\t\t\t\t\t_haikuLocalV6Ips.push_back(ip.ipOnly());\n\t\t\t\t\t___haikuRegisterTapSourceV6(this, ip.ipOnly());\n"""
    bsd_text = replace_once(bsd_text, register_old, register_new, "BSDEthernetTap IPv6 source registration")

if "___haikuUnregisterTapSourceV6(this, ip.ipOnly());" not in bsd_text:
    unregister_old = """\t\t\telse if (ip.isV6()) {\n\t\t\t\t_haikuLocalV6Ips.erase(std::remove(_haikuLocalV6Ips.begin(), _haikuLocalV6Ips.end(), ip.ipOnly()), _haikuLocalV6Ips.end());\n"""
    unregister_new = """\t\t\telse if (ip.isV6()) {\n\t\t\t\t___haikuUnregisterTapSourceV6(this, ip.ipOnly());\n\t\t\t\t_haikuLocalV6Ips.erase(std::remove(_haikuLocalV6Ips.begin(), _haikuLocalV6Ips.end(), ip.ipOnly()), _haikuLocalV6Ips.end());\n"""
    bsd_text = replace_once(bsd_text, unregister_old, unregister_new, "BSDEthernetTap IPv6 source unregistration")

if "HAIKU TAP REROUTE" not in bsd_text:
    reroute_pattern = re.compile(
        r'(\t+else if \(etherType == ZT_ETHERTYPE_IPV6\) \{\n'
        r'\t+___haikuRewriteNdPayloadMacs\(reinterpret_cast<uint8_t\*>\(b \+ 14\), r - 14, _nativeMac, _ztMac\);\n'
        r'\t+\}\n'
        r'\t+\}\n)'
        r'(#endif\n\t+if \(! handled\) \{\n)',
        re.MULTILINE)
    reroute_insertion = """\t\t\t\tif ((! handled) && (etherType == ZT_ETHERTYPE_IPV6) && (_dev.compare(0, 4, "tap/") == 0) && ((r - 14) >= 40)) {\n\t\t\t\t\tconst uint8_t* ipv6 = reinterpret_cast<const uint8_t*>(b + 14);\n\t\t\t\t\tBSDEthernetTap* owner = ___haikuFindTapBySourceV6(ipv6 + 8);\n\t\t\t\t\tif (owner && (owner != this)) {\n\t\t\t\t\t\tchar srcIpStr[INET6_ADDRSTRLEN];\n\t\t\t\t\t\tMAC rerouteFrom(from);\n\t\t\t\t\t\tif ((rerouteFrom == _nativeMac) || (rerouteFrom == _ztMac)) {\n\t\t\t\t\t\t\trerouteFrom = owner->_ztMac;\n\t\t\t\t\t\t}\n\t\t\t\t\t\tfprintf(stderr, "HAIKU TAP REROUTE src=%s fromdev=%s todev=%s" ZT_EOL_S, inet_ntop(AF_INET6, ipv6 + 8, srcIpStr, sizeof(srcIpStr)), _dev.c_str(), owner->_dev.c_str());\n\t\t\t\t\t\tfflush(stderr);\n\t\t\t\t\t\towner->_handler(owner->_arg, (void*)0, owner->_nwid, rerouteFrom, to, etherType, 0, (const void*)(b + 14), r - 14);\n\t\t\t\t\t\thandled = true;\n\t\t\t\t\t}\n\t\t\t\t}\n"""
    bsd_text, reroute_count = reroute_pattern.subn(lambda m: m.group(1) + reroute_insertion + m.group(2), bsd_text, count=1)
    if reroute_count != 1:
        raise SystemExit("unable to apply BSDEthernetTap IPv6 reroute hotfix")

bsd_path.write_text(bsd_text)
