# Installs WireGuard locally
#
# It does: 
# - create and set up server
#   IPv4 and network 10.200.200.0/24
#   port 51820
# - create 3 Clients with IPs *.11, *.12, *.13
# Focus on AWS Lightsail and deployed through Terraform 
# ("sudo" not needed)
# needs net-tools !
#
# marlon.net 2022
# based on https://xalitech.com/wireguard-vpn-server-on-aws-lightsail/

# usual thing: 
sudo apt update -y 
sudo apt upgrade -y

# useful to get IP information
#echo "*** utils installation"
#sudo apt install moreutils -y

# Public IP of Lightsail instance
curl ifconfig.me/ip > myipv4.txt
export serverIP=$(cat 'myipv4.txt')
echo Server IP = ${serverIP}

#-----------------------------------------------------------------------
echo "*** WG installation"
sudo apt install wireguard -y
sudo apt install qrencode -y

echo "*** generate public & private keys for server and clients"
#
umask 077
mkdir wg && mkdir wg/keys && mkdir wg/clients
#
wg genkey | tee wg/keys/${serverIP}_server_private_key  | wg pubkey > wg/keys/${serverIP}_server_public_key
#
for COUNTCLIENTS in 1 2 3 4 5
do
    wg genkey | tee wg/keys/${serverIP}_client${COUNTCLIENTS}_private_key | wg pubkey > wg/keys/${serverIP}_client${COUNTCLIENTS}_public_key 
done

# getting server keys and set variables
export serverPublicKey=$(cat wg/keys/${serverIP}_server_public_key)
export serverPrivateKey=$(cat wg/keys/${serverIP}_server_private_key)

echo "*** generate WireGuard Server configuration (wg0.config)"
echo creating [Interface] section
echo " 
[Interface]
PrivateKey = ${serverPrivateKey}
Address = 10.200.200.1/24
ListenPort = 51820
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ens3 -j MASQUERADE; ip6tables -A FORWARD -i wg0 -j ACCEPT; ip6tables -t nat -A POSTROUTING -o ens3 -j MASQUERADE; iptables -t nat -A POSTROUTING -s 10.200.200.0/24 -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ens3 -j MASQUERADE; ip6tables -D FORWARD -i wg0 -j ACCEPT; ip6tables -t nat -D POSTROUTING -o ens3 -j MASQUERADE; iptables -t nat -D POSTROUTING -s 10.200.200.0/24 -o eth0 -j MASQUERADE
SaveConfig = true 
"| sudo tee /etc/wireguard/wg0.conf

echo creating [Peer] section
export countFiles=0
for FILE in wg/keys/*client*public_key
do
    ((countFiles++))
    echo creating peer $countFiles
    echo "
[Peer] # client${countFiles}
PublicKey = $(cat ${FILE})
AllowedIPs = 10.200.200.1${countFiles}/32
"| sudo tee -a /etc/wireguard/wg0.conf
done

echo $countFiles files found


echo "*** bring the Wireguard interface up and makes sure it is auto start on reboot"
sudo wg-quick up wg0 &&  
sudo systemctl enable wg-quick@wg0.service

echo "*** enable IPv4 forwarding and negate the need to reboot after the change"
sudo sed -i 's/\#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/g' /etc/sysctl.conf
sudo sysctl -p
sudo echo 1 | tee /proc/sys/net/ipv4/ip_forward

#-----------------------------------------------------------------------
echo "### FIREWALL"

# Track VPN connection
sudo iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Enable VPN traffic on the listening port: 51820
sudo iptables -A INPUT -p udp -m udp --dport 51820 -m conntrack --ctstate NEW -j ACCEPT

# TCP & UDP recursive DNS traffic
sudo iptables -A INPUT -s 10.200.200.0/24 -p tcp -m tcp --dport 53 -m conntrack --ctstate NEW -j ACCEPT
sudo iptables -A INPUT -s 10.200.200.0/24 -p udp -m udp --dport 53 -m conntrack --ctstate NEW -j ACCEPT

# Allow forwarding of packets that stay in the VPN tunnel
sudo iptables -A FORWARD -i wg0 -o wg0 -m conntrack --ctstate NEW -j ACCEPT

# Port FW from Server to Client Router - port Helium 44158
#  BETTER Manually !!! sudo iptables -t nat -I PREROUTING -i eth0 -p tcp -m tcp --dport 44158 -j DNAT --to-destination 10.200.200.5:44158

# Flush
sudo iptables -F

echo "make firewall changes persistent"
# prepare to no prompt at all!
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections
# installation
sudo apt install iptables-persistent -y
# survive after boot
sudo systemctl enable netfilter-persistent &&
sudo netfilter-persistent save

echo ***** Confirm IPTABLES configuration :
sudo iptables -L -n -t nat

echo ***** END OF SERVER CONFIGURATION


#-----------------------------------------------------------------------
echo "### For each CLIENT"

export countFiles=0
for FILE in wg/keys/*client*public_key
do
    ((countFiles++))
    echo creating client ${countFiles}

    export clientName=client${countFiles}
    export clientAddress="10.200.200.1${countFiles}/32"
    export clientPrivateKey=$(cat wg/keys/${serverIP}_${clientName}_private_key)

    echo "[Interface] 
Address = ${clientAddress}
PrivateKey = ${clientPrivateKey}
DNS = 1.1.1.1 

[Peer]
PublicKey = ${serverPublicKey}
Endpoint = ${serverIP}:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 21" > wg/clients/${serverIP}_${clientName}.conf

    qrencode -o wg/clients/${serverIP}_${clientName}.png -t png < wg/clients/${serverIP}_${clientName}.conf 
done

# cleanup


# extract clients from server: 
# scp your_server_login@54.166.184.7:wg/clients/* wg/
#
# install net-tools to run wget!
# sudo apt install net-tools -y && sudo wget -L https://github.com/marlon-net/wg-install/raw/master/ubuntu20.sh -O installwg.sh && bash installwg.sh
# 
# DONT FORGET THESE
# sudo iptables -t nat -I PREROUTING -i eth0 -p tcp -m tcp --dport 44158 -j DNAT --to-destination xxx.xxx.xxx.xxx:44158
# sudo iptables -F
# sudo apt install iptables-persistent
# sudo iptables -L -n -t nat

### END


