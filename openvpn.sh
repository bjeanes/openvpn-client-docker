#!/usr/bin/env bash
#===============================================================================
#          FILE: openvpn.sh
#
#         USAGE: ./openvpn.sh
#
#   DESCRIPTION: Entrypoint for openvpn docker container
#
#       OPTIONS: ---
#  REQUIREMENTS: ---
#          BUGS: ---
#         NOTES: ---
#        AUTHOR: David Personette (dperson@gmail.com),
#  ORGANIZATION:
#       CREATED: 09/28/2014 12:11
#      REVISION: 1.0
#===============================================================================

set -o nounset                              # Treat unset variables as an error

# Extra options to pass to the `openvpn` invocation
OPENVPN_OPTS=""

### dns: setup openvpn client DNS
# Arguments:
#   none)
# Return: options to use VPN provider's DNS resolvers
dns() {
    OPENVPN_OPTS="${OPENVPN_OPTS} --script-security 2"
    OPENVPN_OPTS="${OPENVPN_OPTS} --up   /etc/openvpn/update-resolv-conf"
    OPENVPN_OPTS="${OPENVPN_OPTS} --down /etc/openvpn/update-resolv-conf"

    dns() {
        # no-op further calls
        true
    }
}

### firewall: firewall all output not DNS/VPN that's not over the VPN
# Arguments:
#   none)
# Return: configured firewall
firewall() {
    local docker_network=$(ip -o addr show dev eth0 |
                awk '$3 == "inet" {print $4}')

    iptables -F OUTPUT
    iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A OUTPUT -o tap0 -j ACCEPT
    iptables -A OUTPUT -o tun0 -j ACCEPT
    iptables -A OUTPUT -d ${docker_network} -j ACCEPT
    iptables -A OUTPUT -p udp -m udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp -m owner --gid-owner vpn -j ACCEPT 2>/dev/null &&
    iptables -A OUTPUT -p udp -m owner --gid-owner vpn -j ACCEPT || {
        iptables -A OUTPUT -p tcp -m tcp --dport 1194 -j ACCEPT
        iptables -A OUTPUT -p udp -m udp --dport 1194 -j ACCEPT; }
    iptables -A OUTPUT -j DROP
}

### return_route: add a route back to your network, so that return traffic works
# Arguments:
#   network) a CIDR specified network range
# Return: configured return route
return_route() { local gw network="$1"
    gw=$(ip route | awk '/default/ {print $3}')
    ip route add to $network via $gw dev eth0
}

### timezone: Set the timezone for the container
# Arguments:
#   timezone) for example EST5EDT
# Return: the correct zoneinfo file will be symlinked into place
timezone() { local timezone="${1:-EST5EDT}"
    [[ -e /usr/share/zoneinfo/$timezone ]] || {
        echo "ERROR: invalid timezone specified: $timezone" >&2
        return
    }

    if [[ -w /etc/timezone && $(cat /etc/timezone) != $timezone ]]; then
        echo "$timezone" >/etc/timezone
        ln -sf /usr/share/zoneinfo/$timezone /etc/localtime
        dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1
    fi
}

# Add option to openvpn invocation to read auth from file
_auth() { local auth_file="$1"
    OPENVPN_OPTS="$OPENVPN_OPTS --auth-user-pass $auth_file"

    _auth() {
        # no-op further calls
        true
    }
}

### auth: setup openvpn auth
# Arguments:
#   user) user name on VPN
#   pass) password on VPN
auth() { local user="$1" pass="$2" \
               auth_file="/vpn/vpn.auth"

    echo "$user" >$auth_file
    echo "$pass" >>$auth_file
    chmod 0600 $auth_file

    _auth "$auth_file"
}

### vpn: setup openvpn client
# Arguments:
#   server) VPN GW server
#   user) user name on VPN
#   pass) password on VPN
# Return: configured .ovpn file
vpn() { local server="$1" user="$2" pass="$3"
    OPENVPN_OPTS="$OPENVPN_OPTS --remote $server 1194"
    auth "$user" "$pass"
}

### usage: Help
# Arguments:
#   none)
# Return: Help text
usage() { local RC=${1:-0}

    echo "Usage: ${0##*/} [-opt] [command]
Options (fields in '[]' are optional, '<>' are required):
    -h          This help
    -a \"<user>;<pass>\" VPN server authentication
                <user> to authenticate as
                <pass> to authenticate with
    -d          Use the VPN provider's DNS resolvers
    -f          Firewall rules so that only the VPN and DNS are allowed to
                send internet traffic (IE if VPN is down it's offline)
    -r \"<network>\" CIDR network (IE 192.168.1.0/24)
                required arg: \"<network>\"
                <network> add a route to (allows replies once the VPN is up)
    -t \"\"       Configure timezone
                possible arg: \"[timezone]\" - zoneinfo timezone for container
    -v '<server;user;password>' Configure OpenVPN
                required arg: \"<server>;<user>;<password>\"
                <server> to connect to
                <user> to authenticate as
                <password> to authenticate with

The 'command' (if provided and valid) will be run instead of openvpn
" >&2
    exit $RC
}

# Convert ENV options into CLI parameters.
# Push into front of positional params so explicit params can override.
[[ "${FIREWALL:-""}" ]] && set -- -f          "$@"
[[ "${ROUTE:-""}" ]]    && set -- -r "$ROUTE" "$@"
[[ "${TZ:-""}" ]]       && set -- -t "$TZ"    "$@"
[[ "${VPN:-""}" ]]      && set -- -v "$VPN"   "$@"
[[ "${DNS:-""}" ]]      && set -- -d          "$@"

while getopts ":ha:dfr:t:v:" opt; do
    case "$opt" in
        h) usage ;;
        d) dns ;;
        f) firewall ;;
        a) auth "${OPTARG%%;*}" "${OPTARG#*;}" ;;
        r) return_route "$OPTARG" ;;
        t) timezone "$OPTARG" ;;
        v) eval vpn $(sed 's/^\|$/"/g; s/;/" "/g' <<< $OPTARG) ;;
        "?") echo "Unknown option: -$OPTARG"; usage 1 ;;
        ":") echo "No argument value for option: -$OPTARG"; usage 2 ;;
    esac
done
shift $(( OPTIND - 1 ))


if [[ $# -ge 1 && -x $(which $1 2>&-) ]]; then
    exec "$@"
elif [[ $# -ge 1 ]]; then
    echo "ERROR: command not found: $1"
    exit 13
elif ps -ef | egrep -v 'grep|openvpn.sh' | grep -q openvpn; then
    echo "Service already running, please restart container to apply changes"
else
    [[ -e /vpn/vpn.conf ]] || { echo "ERROR: VPN not configured!"; sleep 120; }

    # If and only if a cert file is specified, check that it exists
    cert_file="$(awk '$1=="ca"{print $2}' /vpn/vpn.conf)"
    [[ -z "$cert_file" ]] ||
        [[ -e "$cert_file" ]] ||
        { echo "ERROR: VPN cert missing!"; sleep 120; }

    [[ -x /sbin/resolvconf ]] || { cat >/sbin/resolvconf <<-EOF
		#!/usr/bin/env bash
		conf=/etc/resolv.conf
		[[ -e \${conf}.orig ]] || cp -p \${conf} \${conf}.orig
		if [[ "\${1:-""}" == "-a" ]]; then
		    cat >\${conf}
		elif [[ "\${1:-""}" == "-d" ]]; then
		    cat \${conf}.orig >\${conf}
		fi
		EOF
        chmod +x /sbin/resolvconf; }

    # create the tun device
    [ -d /dev/net ] || mkdir -p /dev/net
    [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200
    exec sg vpn -c "openvpn --config /vpn/vpn.conf $OPENVPN_OPTS"
fi
