#define _GNU_SOURCE

#include <arpa/inet.h>
#include <dlfcn.h>
#include <netdb.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>

#ifndef NI_MAXHOST
#define NI_MAXHOST 1025
#endif

#define MAX_ZT_V4_ROUTES 128
#define MAX_ZT_V6_ROUTES 128
#define POLICY_CACHE_SECONDS 5
#define DEFAULT_POLICY_PATH "@POLICY_STATE_FILE@"

struct ipv4_route {
	struct in_addr network;
	unsigned int prefix_len;
};

struct ipv6_route {
	struct in6_addr network;
	unsigned int prefix_len;
};

struct route_cache {
	time_t loaded_at;
	time_t source_mtime;
	int public_v6_default;
	size_t v4_count;
	size_t v6_count;
	struct ipv4_route v4[MAX_ZT_V4_ROUTES];
	struct ipv6_route v6[MAX_ZT_V6_ROUTES];
};

static struct route_cache g_cache;
static int (*real_getaddrinfo_fn)(const char *, const char *, const struct addrinfo *, struct addrinfo **) = NULL;

static const char *policy_path(void)
{
	const char *path = getenv("HAIKU_NET_FAMILY_POLICY_FILE");
	if (path != NULL && path[0] != '\0')
		return path;
	return DEFAULT_POLICY_PATH;
}

static void load_real_symbols(void)
{
	if (real_getaddrinfo_fn == NULL)
		real_getaddrinfo_fn = (int (*)(const char *, const char *, const struct addrinfo *, struct addrinfo **))dlsym(RTLD_NEXT, "getaddrinfo");
}

static int parse_ipv4_cidr(const char *value, struct ipv4_route *out)
{
	char copy[NI_MAXHOST];
	char *slash;
	unsigned long prefix_len;
	char *endptr = NULL;

	if (value == NULL || out == NULL)
		return 0;

	strncpy(copy, value, sizeof(copy) - 1);
	copy[sizeof(copy) - 1] = '\0';
	slash = strchr(copy, '/');
	if (slash == NULL)
		return 0;
	*slash++ = '\0';

	prefix_len = strtoul(slash, &endptr, 10);
	if (endptr == NULL || *endptr != '\0' || prefix_len > 32)
		return 0;
	if (inet_pton(AF_INET, copy, &out->network) != 1)
		return 0;

	out->prefix_len = (unsigned int)prefix_len;
	return 1;
}

static int parse_ipv6_cidr(const char *value, struct ipv6_route *out)
{
	char copy[NI_MAXHOST];
	char *slash;
	unsigned long prefix_len;
	char *endptr = NULL;

	if (value == NULL || out == NULL)
		return 0;

	strncpy(copy, value, sizeof(copy) - 1);
	copy[sizeof(copy) - 1] = '\0';
	slash = strchr(copy, '/');
	if (slash == NULL)
		return 0;
	*slash++ = '\0';

	prefix_len = strtoul(slash, &endptr, 10);
	if (endptr == NULL || *endptr != '\0' || prefix_len > 128)
		return 0;
	if (inet_pton(AF_INET6, copy, &out->network) != 1)
		return 0;
	if (out->network.s6_addr[0] == 0xff)
		return 0;

	out->prefix_len = (unsigned int)prefix_len;
	return 1;
}

static void refresh_route_cache(void)
{
	FILE *fp;
	char line[2048];
	struct stat st;
	time_t now = time(NULL);
	const char *path = policy_path();

	if (stat(path, &st) != 0) {
		if (g_cache.loaded_at != 0 && (now - g_cache.loaded_at) < POLICY_CACHE_SECONDS)
			return;
		memset(&g_cache, 0, sizeof(g_cache));
		g_cache.loaded_at = now;
		return;
	}

	if (g_cache.loaded_at != 0 && g_cache.source_mtime == st.st_mtime && (now - g_cache.loaded_at) < POLICY_CACHE_SECONDS)
		return;

	memset(&g_cache, 0, sizeof(g_cache));
	g_cache.loaded_at = now;
	g_cache.source_mtime = st.st_mtime;

	fp = fopen(path, "r");
	if (fp == NULL)
		return;

	while (fgets(line, sizeof(line), fp) != NULL) {
		size_t len = strlen(line);
		while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r')) {
			line[--len] = '\0';
		}
		if (strncmp(line, "public_v6_default=", 18) == 0) {
			g_cache.public_v6_default = atoi(line + 18) ? 1 : 0;
			continue;
		}
		if (strncmp(line, "zt_v4=", 6) == 0) {
			struct ipv4_route route4;
			if (g_cache.v4_count >= MAX_ZT_V4_ROUTES)
				continue;
			if (!parse_ipv4_cidr(line + 6, &route4))
				continue;
			g_cache.v4[g_cache.v4_count++] = route4;
			continue;
		}
		if (strncmp(line, "zt_v6=", 6) == 0) {
			struct ipv6_route route6;
			if (g_cache.v6_count >= MAX_ZT_V6_ROUTES)
				continue;
			if (!parse_ipv6_cidr(line + 6, &route6))
				continue;
			g_cache.v6[g_cache.v6_count++] = route6;
		}
	}

	fclose(fp);
}

static int ipv4_matches_zt(const struct in_addr *addr)
{
	size_t i;
	uint32_t addr_host;

	if (addr == NULL)
		return 0;
	addr_host = ntohl(addr->s_addr);

	for (i = 0; i < g_cache.v4_count; ++i) {
		uint32_t net_host = ntohl(g_cache.v4[i].network.s_addr);
		uint32_t mask_host;

		if (g_cache.v4[i].prefix_len == 0)
			return 1;
		mask_host = (g_cache.v4[i].prefix_len == 32) ? 0xffffffffU : (0xffffffffU << (32 - g_cache.v4[i].prefix_len));
		if ((addr_host & mask_host) == (net_host & mask_host))
			return 1;
	}
	return 0;
}

static int ipv6_matches_prefix(const struct in6_addr *addr, const struct ipv6_route *route)
{
	unsigned int full_bytes;
	unsigned int remaining_bits;

	if (addr == NULL || route == NULL)
		return 0;

	full_bytes = route->prefix_len / 8;
	remaining_bits = route->prefix_len % 8;

	if (full_bytes > 0 && memcmp(addr->s6_addr, route->network.s6_addr, full_bytes) != 0)
		return 0;
	if (remaining_bits > 0) {
		uint8_t mask = (uint8_t)(0xff << (8 - remaining_bits));
		if ((addr->s6_addr[full_bytes] & mask) != (route->network.s6_addr[full_bytes] & mask))
			return 0;
	}
	return 1;
}

static int ipv6_matches_zt(const struct in6_addr *addr)
{
	size_t i;

	for (i = 0; i < g_cache.v6_count; ++i) {
		if (ipv6_matches_prefix(addr, &g_cache.v6[i]))
			return 1;
	}
	return 0;
}

static int literal_family(const char *node)
{
	struct in_addr ipv4;
	struct in6_addr ipv6;
	char host[NI_MAXHOST];
	size_t len;

	if (node == NULL)
		return 0;

	if (node[0] == '[') {
		const char *end = strchr(node, ']');
		if (end == NULL)
			return 0;
		len = (size_t)(end - node - 1);
		if (len >= sizeof(host))
			return 0;
		memcpy(host, node + 1, len);
		host[len] = '\0';
		node = host;
	}

	if (inet_pton(AF_INET, node, &ipv4) == 1)
		return AF_INET;
	if (inet_pton(AF_INET6, node, &ipv6) == 1)
		return AF_INET6;
	return 0;
}

static int decide_family(const char *node, const struct addrinfo *result)
{
	int found_v4 = 0;
	int found_v6 = 0;
	int zt_v4 = 0;
	int zt_v6 = 0;
	int literal = literal_family(node);
	const struct addrinfo *it;

	if (literal != 0)
		return literal;

	refresh_route_cache();

	for (it = result; it != NULL; it = it->ai_next) {
		if (it->ai_family == AF_INET && it->ai_addr != NULL) {
			const struct sockaddr_in *sin = (const struct sockaddr_in *)it->ai_addr;
			found_v4 = 1;
			if (ipv4_matches_zt(&sin->sin_addr))
				zt_v4 = 1;
		} else if (it->ai_family == AF_INET6 && it->ai_addr != NULL) {
			const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)it->ai_addr;
			found_v6 = 1;
			if (ipv6_matches_zt(&sin6->sin6_addr))
				zt_v6 = 1;
		}
	}

	if (zt_v6)
		return AF_INET6;
	if (zt_v4)
		return AF_INET;
	if (!g_cache.public_v6_default && found_v4)
		return AF_INET;
	if (found_v6)
		return AF_INET6;
	if (found_v4)
		return AF_INET;
	return 0;
}

static void reorder_addrinfo(struct addrinfo **res, int preferred_family)
{
	struct addrinfo *preferred_head = NULL;
	struct addrinfo *preferred_tail = NULL;
	struct addrinfo *other_head = NULL;
	struct addrinfo *other_tail = NULL;
	struct addrinfo *it;

	if (res == NULL || *res == NULL || preferred_family == 0)
		return;

	for (it = *res; it != NULL;) {
		struct addrinfo *next = it->ai_next;
		it->ai_next = NULL;

		if (it->ai_family == preferred_family) {
			if (preferred_tail != NULL)
				preferred_tail->ai_next = it;
			else
				preferred_head = it;
			preferred_tail = it;
		} else {
			if (other_tail != NULL)
				other_tail->ai_next = it;
			else
				other_head = it;
			other_tail = it;
		}

		it = next;
	}

	if (preferred_tail != NULL)
		preferred_tail->ai_next = other_head;
	*res = (preferred_head != NULL) ? preferred_head : other_head;
}

int getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res)
{
	int rc;
	int preferred_family;

	load_real_symbols();
	if (real_getaddrinfo_fn == NULL)
		return EAI_SYSTEM;

	rc = real_getaddrinfo_fn(node, service, hints, res);
	if (rc != 0 || res == NULL || *res == NULL)
		return rc;

	if (hints != NULL && hints->ai_family != AF_UNSPEC)
		return rc;

	preferred_family = decide_family(node, *res);
	if (preferred_family != 0)
		reorder_addrinfo(res, preferred_family);

	return rc;
}
