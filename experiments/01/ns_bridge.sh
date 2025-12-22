#!/usr/bin/env bash
set -Eeuo pipefail

# 需要 root。支持 ./script_bridges_in_ns.sh down 清理
# 拓扑（桥放在对应 ns 中）：
#   ns1 内部：brL —— 接口：ns1 自身的 lgw0(三层口)，lsw0(桥口)，以及三条叶子上行 lv{i}br
#   ns3 内部：brR —— 接口：ns3 自身的 rgw0(三层口)，rsw0(桥口)，以及三条叶子上行 rv{i}br
# 整个脚本的逻辑：先建立变量名，然后进行关系建立，最后ip分配，就可以进行运行了
# 对桥的理解：建立了内外部的联系，叶子是与外部连接通道（发送和接受），用哪个叶子由gw0决定；gw0还决定
# 分配到内部哪个主机，而执行这的就是sw0

NS1=ns1; NS2=ns2; NS3=ns3
LNS=(ns1a ns1b ns1c)
RNS=(ns3a ns3b ns3c)

# 核心 P2P veth
V12A=veth12a  # ns1
V12B=veth12b  # ns2
V23A=veth23a  # ns2
V23B=veth23b  # ns3

# ns1 内的桥与接口
BRL=brL
LGW=lgw0   # ns1 上的三层口（配置 10.0.1.1/24）
LSW=lsw0   # 接到 BRL 的桥口

# ns3 内的桥与接口
BRR=brR
RGW=rgw0   # ns3 上的三层口（配置 10.0.3.1/24）
RSW=rsw0   # 接到 BRR 的桥口

# 左/右 侧叶子上行（进 ns1/ns3 一端命名 *_br；叶子 ns 一端命名 *_ns）
LV_NS=(lv1_ns lv2_ns lv3_ns)
LV_BR=(lv1_br lv2_br lv3_br)
RV_NS=(rv1_ns rv2_ns rv3_ns)
RV_BR=(rv1_br rv2_br rv3_br)

# 地址规划
NS1_P2P=10.0.12.1/30
NS2_P2P_L=10.0.12.2/30
NS2_P2P_R=10.0.23.1/30
NS3_P2P=10.0.23.2/30

LAN_L_CIDR=10.0.1.0/24
LAN_L_GW=10.0.1.1
LAN_L_LEAVES=(10.0.1.11 10.0.1.12 10.0.1.13)

LAN_R_CIDR=10.0.3.0/24
LAN_R_GW=10.0.3.1
LAN_R_LEAVES=(10.0.3.11 10.0.3.12 10.0.3.13)

exists_ns(){ ip netns list | awk '{print $1}' | grep -qx "$1"; }
exists_link(){ ip link show "$1" &>/dev/null; }

cleanup(){
  set +e
  # 尝试删除所有我们命名过的 veth（不管在哪个 ns）
  for L in "$V12A" "$V12B" "$V23A" "$V23B" "${LV_BR[@]}" "${RV_BR[@]}"; do
    if exists_link "$L"; then ip link del "$L" 2>/dev/null || true; fi
  done
  # 在各 ns 内尝试删除接口/桥
  for ns in "$NS1" "$NS2" "$NS3" "${LNS[@]}" "${RNS[@]}"; do
    if exists_ns "$ns"; then
      ip -n "$ns" link del "$LGW" 2>/dev/null || true
      ip -n "$ns" link del "$LSW" 2>/dev/null || true
      ip -n "$ns" link del "$RGW" 2>/dev/null || true
      ip -n "$ns" link del "$RSW" 2>/dev/null || true
      ip -n "$ns" link del "$BRL" 2>/dev/null || true
      ip -n "$ns" link del "$BRR" 2>/dev/null || true
      for d in "${LV_NS[@]}" "${RV_NS[@]}"; do ip -n "$ns" link del "$d" 2>/dev/null || true; done
    fi
  done
  # 删 ns
  for ns in "${RNS[@]}" "${LNS[@]}" "$NS3" "$NS2" "$NS1"; do
    exists_ns "$ns" && ip netns del "$ns" 2>/dev/null || true
  done
}

trap 'echo "[!] 出错，清理中..."; cleanup' ERR

if [[ "${1:-}" == "down" ]]; then
  echo "[*] 清理资源..."
  cleanup
  echo "[*] 完成清理。"; exit 0
fi

echo "[*] 预清理..."
cleanup || true

echo "[*] 创建 namespaces..."
ip netns add "$NS1"; ip netns add "$NS2"; ip netns add "$NS3"
for ns in "${LNS[@]}" "${RNS[@]}"; do ip netns add "$ns"; done

echo "[*] 创建核心 P2P veth..."
ip link add "$V12A" type veth peer name "$V12B"
ip link set "$V12A" netns "$NS1"
ip link set "$V12B" netns "$NS2"

ip link add "$V23A" type veth peer name "$V23B"
ip link set "$V23A" netns "$NS2"
ip link set "$V23B" netns "$NS3"

echo "[*] 在 ns1 内创建桥 $BRL，并准备 ns1 自身入桥的 veth 对..."
ip netns exec "$NS1" ip link add "$BRL" type bridge
ip netns exec "$NS1" ip link set "$BRL" up
# ns1 自身接入桥：同 ns 内一对 veth：LGW(三层口) <-> LSW(桥口)
ip netns exec "$NS1" ip link add "$LGW" type veth peer name "$LSW"
ip netns exec "$NS1" ip link set "$LSW" master "$BRL"
ip netns exec "$NS1" ip link set "$LSW" up
ip netns exec "$NS1" ip link set "$LGW" up

echo "[*] 在 ns3 内创建桥 $BRR，并准备 ns3 自身入桥的 veth 对..."
ip netns exec "$NS3" ip link add "$BRR" type bridge
ip netns exec "$NS3" ip link set "$BRR" up
ip netns exec "$NS3" ip link add "$RGW" type veth peer name "$RSW"
ip netns exec "$NS3" ip link set "$RSW" master "$BRR"
ip netns exec "$NS3" ip link set "$RSW" up
ip netns exec "$NS3" ip link set "$RGW" up

echo "[*] 左侧三叶子：将叶子上行的另一端移入 ns1 并接入 brL..."
for i in 0 1 2; do
  # 创建 veth，先都在 root
  ip link add "${LV_BR[$i]}" type veth peer name "${LV_NS[$i]}"
  # 叶子端进叶子 ns
  ip link set "${LV_NS[$i]}" netns "${LNS[$i]}"
  # 上行端进 ns1 并接入 brL
  ip link set "${LV_BR[$i]}" netns "$NS1"
  ip netns exec "$NS1" ip link set "${LV_BR[$i]}" master "$BRL"
  ip netns exec "$NS1" ip link set "${LV_BR[$i]}" up
done

echo "[*] 右侧三叶子：将叶子上行的另一端移入 ns3 并接入 brR..."
for i in 0 1 2; do
  ip link add "${RV_BR[$i]}" type veth peer name "${RV_NS[$i]}"
  ip link set "${RV_NS[$i]}" netns "${RNS[$i]}"
  ip link set "${RV_BR[$i]}" netns "$NS3"
  ip netns exec "$NS3" ip link set "${RV_BR[$i]}" master "$BRR"
  ip netns exec "$NS3" ip link set "${RV_BR[$i]}" up
done

echo "[*] 启动各 ns 的 lo..."
for ns in "$NS1" "$NS2" "$NS3" "${LNS[@]}" "${RNS[@]}"; do
  ip -n "$ns" link set lo up
done

echo "[*] 配置核心 P2P 地址并启用接口..."
ip -n "$NS1" addr add "$NS1_P2P" dev "$V12A"; ip -n "$NS1" link set "$V12A" up
ip -n "$NS2" addr add "$NS2_P2P_L" dev "$V12B"; ip -n "$NS2" link set "$V12B" up
ip -n "$NS2" addr add "$NS2_P2P_R" dev "$V23A"; ip -n "$NS2" link set "$V23A" up
ip -n "$NS3" addr add "$NS3_P2P" dev "$V23B"; ip -n "$NS3" link set "$V23B" up

echo "[*] 配置 ns1/左侧 LAN 地址..."
ip -n "$NS1" addr add "${LAN_L_GW}/24" dev "$LGW"
for i in 0 1 2; do
  ns="${LNS[$i]}"
  ip -n "$ns" addr add "${LAN_L_LEAVES[$i]}/24" dev "${LV_NS[$i]}"
  ip -n "$ns" link set "${LV_NS[$i]}" up
done

echo "[*] 配置 ns3/右侧 LAN 地址..."
ip -n "$NS3" addr add "${LAN_R_GW}/24" dev "$RGW"
for i in 0 1 2; do
  ns="${RNS[$i]}"
  ip -n "$ns" addr add "${LAN_R_LEAVES[$i]}/24" dev "${RV_NS[$i]}"
  ip -n "$ns" link set "${RV_NS[$i]}" up
done

echo "[*] 开启 ns1/ns2/ns3 的 IPv4 转发..."
ip netns exec "$NS1" sysctl -w net.ipv4.ip_forward=1 >/dev/null
ip netns exec "$NS2" sysctl -w net.ipv4.ip_forward=1 >/dev/null
ip netns exec "$NS3" sysctl -w net.ipv4.ip_forward=1 >/dev/null

echo "[*] 配置静态路由..."
# ns1：到右侧 LAN 与 ns2-ns3链路均走 10.0.12.2
ip -n "$NS1" route add "$LAN_R_CIDR" via 10.0.12.2 dev "$V12A" || true
ip -n "$NS1" route add 10.0.23.0/30 via 10.0.12.2 dev "$V12A" || true

# ns3：到左侧 LAN 与 ns1-ns2链路均走 10.0.23.1
ip -n "$NS3" route add "$LAN_L_CIDR" via 10.0.23.1 dev "$V23B" || true
ip -n "$NS3" route add 10.0.12.0/30 via 10.0.23.1 dev "$V23B" || true

# ns2：知道两边 LAN
ip -n "$NS2" route add "$LAN_L_CIDR" via 10.0.12.1 dev "$V12B" || true
ip -n "$NS2" route add "$LAN_R_CIDR" via 10.0.23.2 dev "$V23A" || true

# 左/右叶子：默认路由指向各自网关
for ns in "${LNS[@]}"; do ip -n "$ns" route add default via "$LAN_L_GW" || true; done
for ns in "${RNS[@]}"; do ip -n "$ns" route add default via "$LAN_R_GW" || true; done

echo "[*] 连通性快速测试..."
set +e
ip netns exec ns1a ping -c1 -W1 10.0.3.11 >/dev/null && echo "ns1a → ns3a OK" || echo "ns1a → ns3a FAIL"
ip netns exec ns3b ping -c1 -W1 10.0.1.12 >/dev/null && echo "ns3b → ns1b OK" || echo "ns3b → ns1b FAIL"
ip netns exec ns1c ping -c1 -W1 10.0.23.2 >/dev/null && echo "ns1c → ns3(P2P) OK" || echo "ns1c → ns3(P2P) FAIL"
ip netns exec ns3c ping -c1 -W1 10.0.12.1 >/dev/null && echo "ns3c → ns1(P2P) OK" || echo "ns3c → ns1(P2P) FAIL"
set -e

cat <<EOF

[*] 部署完成（桥已放入对应 ns）！

ns1 内：
  bridge $BRL
  三层口: $LGW = $LAN_L_GW/24
  叶子上行端口: ${LV_BR[*]} (均 master $BRL)

ns3 内：
  bridge $BRR
  三层口: $RGW = $LAN_R_GW/24
  叶子上行端口: ${RV_BR[*]} (均 master $BRR)

核心：
  $NS1 ($V12A: $NS1_P2P) <-> $NS2 ($V12B: $NS2_P2P_L, $V23A: $NS2_P2P_R) <-> $NS3 ($V23B: $NS3_P2P)

排错常用：
  ip netns list
  ip -n $NS1 addr; ip -n $NS3 addr
  ip -n $NS1 bridge link; ip -n $NS3 bridge link
  ip -n $NS2 route; ip -n $NS1 route; ip -n $NS3 route

清理：
  sudo bash $(basename "$0") down
EOF
