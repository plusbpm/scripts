#!/bin/bash

BASE_API_URL=https://vvpn.loan/app/v1/user

AVAILABLE_LOCATIONS_TMP=available_locations.tmp
USER_INFO_TMP=user_info.json.tmp
STARTED_TMP=vpn_started.tmp
LOG_TMP=logs.tmp

ACTION_ITEMS="on\
    Включить\
    off\
    Выключить"
. ./predefined_locations.sh
LOCATION_ITEMS="$ACTION_ITEMS $LOCATION_ITEMS"

Di() {
    dialog --backtitle "Дядя Ваня VPN" --clear --colors --stdout "$@"
}

msg() {
    MSGBOX_HEIGHT=$((`tput lines` * 2 / 3))
    MSGBOX_WIDTH=$((`tput cols` * 2 / 3))
    Di --msgbox "$1" $MSGBOX_HEIGHT $MSGBOX_WIDTH
}

start_ssredir() {
    (nohup ss-redir -s $REMOTE_IP -p $REMOTE_PORT -m $REMOTE_METHOD -k $REMOTE_PASSWORD -b 127.0.0.1 -l 60080 --no-delay -u -T -v </dev/null &>>/var/log/ss-redir.log &)
}

stop_ssredir() {
    kill -9 $(pidof ss-redir) &>/dev/null
}

start_iptables() {
    ##################### SSREDIR #####################
    iptables -t mangle -N SSREDIR

    # connection-mark -> packet-mark
    iptables -t mangle -A SSREDIR -j CONNMARK --restore-mark
    iptables -t mangle -A SSREDIR -m mark --mark 0x2333 -j RETURN

    # please modify MyIP, MyPort, etc.
    # ignore traffic sent to ss-server
    iptables -t mangle -A SSREDIR -p tcp -d $REMOTE_IP --dport $REMOTE_PORT -j RETURN
    iptables -t mangle -A SSREDIR -p udp -d $REMOTE_IP --dport $REMOTE_PORT -j RETURN

    # ignore traffic sent to reserved addresses
    iptables -t mangle -A SSREDIR -d 0.0.0.0/8          -j RETURN
    iptables -t mangle -A SSREDIR -d 10.0.0.0/8         -j RETURN
    iptables -t mangle -A SSREDIR -d 100.64.0.0/10      -j RETURN
    iptables -t mangle -A SSREDIR -d 127.0.0.0/8        -j RETURN
    iptables -t mangle -A SSREDIR -d 169.254.0.0/16     -j RETURN
    iptables -t mangle -A SSREDIR -d 172.16.0.0/12      -j RETURN
    iptables -t mangle -A SSREDIR -d 192.0.0.0/24       -j RETURN
    iptables -t mangle -A SSREDIR -d 192.0.2.0/24       -j RETURN
    iptables -t mangle -A SSREDIR -d 192.88.99.0/24     -j RETURN
    iptables -t mangle -A SSREDIR -d 192.168.0.0/16     -j RETURN
    iptables -t mangle -A SSREDIR -d 198.18.0.0/15      -j RETURN
    iptables -t mangle -A SSREDIR -d 198.51.100.0/24    -j RETURN
    iptables -t mangle -A SSREDIR -d 203.0.113.0/24     -j RETURN
    iptables -t mangle -A SSREDIR -d 224.0.0.0/4        -j RETURN
    iptables -t mangle -A SSREDIR -d 240.0.0.0/4        -j RETURN
    iptables -t mangle -A SSREDIR -d 255.255.255.255/32 -j RETURN

    # mark the first packet of the connection
    iptables -t mangle -A SSREDIR -p tcp --syn                      -j MARK --set-mark 0x2333
    iptables -t mangle -A SSREDIR -p udp -m conntrack --ctstate NEW -j MARK --set-mark 0x2333

    # packet-mark -> connection-mark
    iptables -t mangle -A SSREDIR -j CONNMARK --save-mark

    ##################### OUTPUT #####################
    # proxy the outgoing traffic from this machine
    iptables -t mangle -A OUTPUT -p tcp -m addrtype --src-type LOCAL ! --dst-type LOCAL -j SSREDIR
    iptables -t mangle -A OUTPUT -p udp -m addrtype --src-type LOCAL ! --dst-type LOCAL -j SSREDIR

    ##################### PREROUTING #####################
    # proxy traffic passing through this machine (other->other)
    iptables -t mangle -A PREROUTING -p tcp -m addrtype ! --src-type LOCAL ! --dst-type LOCAL -j SSREDIR
    iptables -t mangle -A PREROUTING -p udp -m addrtype ! --src-type LOCAL ! --dst-type LOCAL -j SSREDIR

    # hand over the marked package to TPROXY for processing
    iptables -t mangle -A PREROUTING -p tcp -m mark --mark 0x2333 -j TPROXY --on-ip 127.0.0.1 --on-port 60080
    iptables -t mangle -A PREROUTING -p udp -m mark --mark 0x2333 -j TPROXY --on-ip 127.0.0.1 --on-port 60080
}

stop_iptables() {
    ##################### PREROUTING #####################
    iptables -t mangle -D PREROUTING -p tcp -m mark --mark 0x2333 -j TPROXY --on-ip 127.0.0.1 --on-port 60080 &>/dev/null
    iptables -t mangle -D PREROUTING -p udp -m mark --mark 0x2333 -j TPROXY --on-ip 127.0.0.1 --on-port 60080 &>/dev/null

    iptables -t mangle -D PREROUTING -p tcp -m addrtype ! --src-type LOCAL ! --dst-type LOCAL -j SSREDIR &>/dev/null
    iptables -t mangle -D PREROUTING -p udp -m addrtype ! --src-type LOCAL ! --dst-type LOCAL -j SSREDIR &>/dev/null

    ##################### OUTPUT #####################
    iptables -t mangle -D OUTPUT -p tcp -m addrtype --src-type LOCAL ! --dst-type LOCAL -j SSREDIR &>/dev/null
    iptables -t mangle -D OUTPUT -p udp -m addrtype --src-type LOCAL ! --dst-type LOCAL -j SSREDIR &>/dev/null

    ##################### SSREDIR #####################
    iptables -t mangle -F SSREDIR &>/dev/null
    iptables -t mangle -X SSREDIR &>/dev/null
}

start_iproute2() {
    ip route add local default dev lo table 100
    ip rule  add fwmark 0x2333        table 100
}

stop_iproute2() {
    ip rule  del   table 100 &>/dev/null
    ip route flush table 100 &>/dev/null
}

start_resolvconf() {
    # or nameserver 8.8.8.8, etc.
    echo "nameserver 1.1.1.1" >/etc/resolv.conf
}

stop_resolvconf() {
    echo "nameserver 114.114.114.114" >/etc/resolv.conf
}

start() {
    echo "start ..."
    start_ssredir
    start_iptables
    start_iproute2
    start_resolvconf
    touch ./$STARTED_TMP
    echo "start end"
}

stop() {
    echo "stop ..."
    stop_resolvconf
    stop_iproute2
    stop_iptables
    stop_ssredir
    rm -f ./$STARTED_TMP
    echo "stop end"
}

restart() {
    stop
    sleep 1
    start
}

read_current_location() {
    echo "$BASE_API_URL/info?token=$TOKEN -o $USER_INFO_TMP"
    curl "$BASE_API_URL/info?token=$TOKEN" -o $USER_INFO_TMP
    echo ''
    export RESULT_LOCATION=$(cat $USER_INFO_TMP | jq ".location" | sed 's/"//g')
    export REMOTE_IP=$(cat $USER_INFO_TMP | jq ".tokens.${RESULT_LOCATION}.accessUrl" | grep -Eo "([0-9]{1,3}\.){3}[0-9]{1,3}" | sed 's/"//g')
    export REMOTE_PORT=$(cat $USER_INFO_TMP | jq ".tokens.${RESULT_LOCATION}.port" | sed 's/"//g')
    export REMOTE_PASSWORD=$(cat $USER_INFO_TMP | jq ".tokens.${RESULT_LOCATION}.password" | sed 's/"//g')
    export REMOTE_METHOD=$(cat $USER_INFO_TMP | jq ".tokens.${RESULT_LOCATION}.method" | sed 's/"//g')
    rm -f $USER_INFO_TMP
}

log() {
    echo "$@" >> ./$LOG_TMP
}

read_available_locations() {
    TOO_OLD_LOCATIONS=$(find ./available_locations.tmp -mmin +120 -type f)
    if [ ! -z "$TOO_OLD_LOCATIONS" ]; then 
        rm -f $AVAILABLE_LOCATIONS_TMP
    fi
    if [ ! -f $AVAILABLE_LOCATIONS_TMP ]; then 
        log "https://api.vanyavpn.com/web/v1/sync/available-locations"
        curl https://api.vanyavpn.com/web/v1/sync/available-locations -o $AVAILABLE_LOCATIONS_TMP
        log ''
        LIST=$(cat "${AVAILABLE_LOCATIONS_TMP}" | jq -r '.[] | @base64')
        TOTAL=$(echo $LIST | wc -w)

        echo $ACTION_ITEMS > $AVAILABLE_LOCATIONS_TMP
        (
            for row in $LIST; do
                CURRENT=$(($CURRENT + 1))
                _jq() {
                    echo ${row} | base64 --decode | jq -r ${1}
                }
                echo "\
                    $(_jq '.value')\
                    $(echo "$(_jq '.description') $(_jq '.speed')" | sed 's/ /\xc2\xa0/g')" >> $AVAILABLE_LOCATIONS_TMP
                echo $((100 * $CURRENT / $TOTAL)) 
            done
        ) | dialog --gauge "Загрузка локаций" 0 0

    fi
    LOCATION_ITEMS=$(cat $AVAILABLE_LOCATIONS_TMP)
}

start_or_restart() {
    if [ -f ./$STARTED_TMP ]; then
        restart
        exit 0
    fi
    start
}

main() {
    if [ -f ./.env.sh ]; then
        . ./.env.sh
    else
        msg "Необходимо создать файл .env.sh"
        exit 0
    fi

    if [ -z "$TOKEN" ]; then
        msg "Необходимо установить токен доступа в переменную TOKEN"
        exit 0
    fi

    read_available_locations
    NEXT_LOCATION=$(Di --menu 'Выбор локации' 0 0 $((`tput lines` / 2)) $LOCATION_ITEMS)

    if [ -z $NEXT_LOCATION ]; then
        tput reset
        exit 0
    fi

    if [ "$NEXT_LOCATION" == "off" ]; then
        log "Stop VPN"
        stop
        exit 0
    fi

    read_current_location

    if  [ "$NEXT_LOCATION" == "on" ]; then
        log "Start VPN"
        start_or_restart
        exit 0
    fi

    log NEXT_LOCATION=$NEXT_LOCATION
    if [ ! "$RESULT_LOCATION" == "$NEXT_LOCATION" ]; then
        log "$BASE_API_URL/location/change?token=$TOKEN&location=$NEXT_LOCATION"
        curl "$BASE_API_URL/location/change?token=$TOKEN&location=$NEXT_LOCATION"
        sleep 1
        read_current_location
    fi

    start_or_restart
}

log `date` '============ START'
main
log `date` '------------ END \n'