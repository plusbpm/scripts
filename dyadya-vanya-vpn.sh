#!/bin/bash

BASE_API_URL=https://vvpn.loan/app/v1/user
USER_INFO_TMP=user_info.json.tmp
LOCATION_SWITCH_TMP=location_switch.tmp
STARTED_TMP=vpn_started.tmp
LOG_TMP=logs.tmp

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
    echo "$BASE_API_URL/info?token=$TOKEN" -o $USER_INFO_TMP
    curl "$BASE_API_URL/info?token=$TOKEN" -o $USER_INFO_TMP
    export RESULT_LOCATION=$(cat $USER_INFO_TMP | jq ".location" | sed 's/"//g')
    export REMOTE_IP=$(cat $USER_INFO_TMP | jq ".tokens.${RESULT_LOCATION}.accessUrl" | grep -Eo "([0-9]{1,3}\.){3}[0-9]{1,3}" | sed 's/"//g')
    export REMOTE_PORT=$(cat $USER_INFO_TMP | jq ".tokens.${RESULT_LOCATION}.port" | sed 's/"//g')
    export REMOTE_PASSWORD=$(cat $USER_INFO_TMP | jq ".tokens.${RESULT_LOCATION}.password" | sed 's/"//g')
    export REMOTE_METHOD=$(cat $USER_INFO_TMP | jq ".tokens.${RESULT_LOCATION}.method" | sed 's/"//g')
    echo RESULT_LOCATION=$RESULT_LOCATION REMOTE=$REMOTE_IP:$REMOTE_PORT REMOTE_PASSWORD=$REMOTE_PASSWORD REMOTE_METHOD=$REMOTE_METHOD
    rm -f $USER_INFO_TMP
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

    NEXT_LOCATION=$(Di --menu 'Выбор локации' 0 0 $((`tput lines` / 2)) $LOCATION_ITEMS)
    if [ -z $NEXT_LOCATION ]; then
        tput resetexit 0
    fi
    if [ "$NEXT_LOCATION" == "none" ]; then
        echo "Stop VPN"
        stop
        rm -f ./$LOG_TMP
        exit 0
    fi
    if  [ "$NEXT_LOCATION" == "current" ]; then
        echo "Start VPN"
        read_current_location
        start
        exit 0
    fi
    if [ -f ./$LOCATION_SWITCH_TMP ]; then
        msg "Смена локации в процессе или не очищен файл индикатор '$LOCATION_SWITCH_TMP'"
        tput reset
        exit 0
    fi
    touch ./$LOCATION_SWITCH_TMP

    read_current_location

    echo NEXT_LOCATION=$NEXT_LOCATION

    if [ "$RESULT_LOCATION" == "$NEXT_LOCATION" ] && [ -f ./$STARTED_TMP ]; then
        rm -f ./$LOCATION_SWITCH_TMP
        msg "Выбранная локация уже активна и подключена, либо не удален файл $STARTED_TMP"
        exit 0
    fi

    if [ "$RESULT_LOCATION" == "$NEXT_LOCATION" ] && [ ! -f ./$STARTED_TMP ]; then
        rm -f $LOCATION_SWITCH_TMP
        start
        exit 0
    fi

    echo "$BASE_API_URL/location/change?token=$TOKEN&location=$NEXT_LOCATION"
    curl "$BASE_API_URL/location/change?token=$TOKEN&location=$NEXT_LOCATION"
    echo 'sleep 5 sec'
    sleep 5
    read_current_location
    restart
    rm -f $LOCATION_SWITCH_TMP
}

LOCATION_ITEMS="\
    current Включить\
    none Выключить\
    frankfurt Германия\
    stockholm Швеция\
    tokyo Япония\
    oregon США\
    montreal Канада\
    almaty Казахстан\
    izmir Турция\
    sydney Австралия\
    amsterdam Нидерланды\
    bangalore Индия\
    singapore Сингапур\
    london Великобритания\
    warszawa Польша\
    hongkong Гонконг\
    dublin Ирландия\
    bishkek Киргизия\
    tbilisi Грузия\
    helsinki Финляндия\
    tallin Эстония\
    mexico Мексика\
    oslo Норвегия\
    palermo Италия\
    bangkok Таиланд\
    bucharest Румыния\
    lisbon Португалия\
    pisek Чехия\
    chisinau Молдова\
    riga Латвия\
    sofia Болгария\
    madrid Испания\
    zurich Швейцария\
    athens Греция\
    marseille Франция\
    johannesburg ЮАР\
    vienna Австрия\
    seoul ЮжнаяКорея\
    budapest Венгрия\
    belgrade Сербия\
    copenhagen Дания\
    yerevan Армения\
    dubai ОАЭ\
    vilnius Литва\
    cairo Египет\
    zagreb Хорватия\
    brussels Бельгия\
    reykjavik Исландия\
    minsk Беларусь\
    skopje СевернаяМакедония\
    ljubljana Словения\
    santiago Чили\
    hanoi Вьетнам\
    baku Азербайджан\
    kathmandu Непал\
    karachi Пакистан\
    ulaanbaatar Монголия\
    bratislava Словакия\
    limassol Кипр\
    ballasalla ОстровМэн\
    jakarta Индонезия\
    manila Филиппины\
    taipei Тайвань\
    tashkent Узбекистан\
    panama Панама\
    guatemala Гватемала\
    tunis Тунис\
    sarajevo БоснияиГерцеговина\
    lagos Нигерия\
    luxembourg Люксембург\
    bogota Колумбия\
    dhaka Бангладеш\
    riyadh СаудовскаяАравия\
    manama Бахрейн\
    muscat Оман\
    lima Перу\
    quito Эквадор\
    auckland НоваяЗеландия\
    montevideo Уругвай\
    tirana Албания\
    algiers Алжир\
    nairob Кения\
    phnom-penh Камбоджа\
    buenos-aires Аргентина\
    petah-tikva Израиль\
    san-juan ПуэртоРико\
    kuala-lumpur Малайзия\
    san-jose КостаРика\
    sao-paulo Бразилия\
"

echo `date` START >> ./$LOG_TMP
main >> ./$LOG_TMP
echo `date` END >> ./$LOG_TMP