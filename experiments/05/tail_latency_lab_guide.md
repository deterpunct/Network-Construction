# 网络传输长尾效应实验指导书

> 依据 `docs/network_latency_long_tail.md` ，完成一次“从网络注入 → 计算作业 → 观测验证”的闭环实验。所有命令均在仓库根目录执行。

## 1. 实验目标
- 利用 `experiments/01/ns.sh` 的五命名空间环拓扑，构造可控的网络延迟环境，并注入随机长尾（`tc netem delay 5ms 2ms 25%` 等）。
- 分层采集指标（`tc qdisc show`、`nstat`、`ip netns exec <ns> sysctl net.ipv4.ip_forward`、作业级日志）验证长尾如何放大到业务层。
- 记录至少一条成功往返（ping/iperf）结果与 tail 观察，撰写实验报告。

## 2. 预备知识与工具
- 熟悉 Bash + `set -Eeuo pipefail`、`ip netns`、`tc netem`、`iperf3`/`ping`.
- 推荐安装：`shellcheck`、`python3`, `iperf3`, `tcpdump`.

## 3. 目录与资源
```
experiments/05/
└── tail_latency_lab_guide.md  # 本指导书
```
公共拓扑脚本位于 `experiments/01/ns.sh`；如需桥接拓扑可参考 `experiments/01/ns_bridge.sh`。

## 4. 环境准备
1. **拉起拓扑**
   ```bash
   sudo bash experiments/01/ns.sh
   ip netns list
   ```
2. **记录接口映射**（示例）  
   `ns1: veth12a (10.0.12.1/30), veth51b (10.0.51.2/30)`  
   `ns2: veth12b (10.0.12.2/30), veth23a (10.0.23.1/30)`  
   以此类推直至 `ns5`。
3. **检查基础连通性**
   ```bash
   ip netns exec ns1 ping -c 4 10.0.23.2
   ip netns exec ns3 ping -c 4 10.0.51.2
   ```
4. **录入初始观测**  
   - `ip netns exec ns1 sysctl net.ipv4.ip_forward`
   - `ip netns exec ns1 tc qdisc show`
   - `ip netns exec ns1 nstat -az | head`

## 5. 基线测试阶段
1. **吞吐/延迟基线**

   ```bash
   sudo bash -c '
   # 清理
   pkill -9 iperf 2>/dev/null
   pkill -9 iperf3 2>/dev/null
   fuser -k 5001/tcp 2>/dev/null
   sleep 2
   
   # 运行
   mkdir -p logs
   echo "=== 启动服务器 (ns1:10.0.12.1) ==="
   ip netns exec ns1 iperf -s &
   SERVER_PID=$!
   sleep 3
   
   echo "=== 带宽测试 (ns3 -> ns1) ==="
   # 重要：连接 ns1 的 IP，不是 ns3 自己的 IP
   ip netns exec ns3 iperf -c 10.0.12.1 -t 20 -i 2
   
   echo "=== Ping测试 (ns5 -> ns1) ==="
   ip netns exec ns5 ping -c 50 -i 0.2 10.0.12.1 > logs/ping_baseline_ns5.txt
   
   pkill iperf 2>/dev/null
   echo "=== 完成 ==="
   ```
   
2. **记录统计**  
   - 计算 p50/p90/p99 RTT。
     
     ```bash
     # 1. 提取所有 RTT 时间
     grep "time=" logs/ping_baseline_ns5.txt | awk -F'time=' '{print $2}' | awk '{print $1}' > rtt_times.txt
     # 2. 排序并计算百分位数
     sort -n rtt_times.txt > sorted_rtt.txt
     TOTAL=$(wc -l < sorted_rtt.txt)      
     # P50 (中位数)
     P50_LINE=$((TOTAL * 50 / 100))
     P50=$(sed -n "${P50_LINE}p" sorted_rtt.txt)     
     # P90 (90百分位)
     P90_LINE=$((TOTAL * 90 / 100))
     P90=$(sed -n "${P90_LINE}p" sorted_rtt.txt)   
     # P99 (99百分位)
     P99_LINE=$((TOTAL * 99 / 100))
     P99=$(sed -n "${P99_LINE}p" sorted_rtt.txt)     
     echo "P50 RTT: $P50 ms"
     echo "P90 RTT: $P90 ms"
     echo "P99 RTT: $P99 ms"
     ```
     
   - 保存 `iperf3` 带宽和重传数-- 取最后一行的结果，重传数取决于掉包率。
3. **清理临时服务**  
   ```bash
   ip netns exec ns1 pkill iperf2 || true
   ```

## 6. 长尾注入与观测
1. **选择链路**（推荐在 `ns2`→`ns3` 的 `veth23a` 注入）
   ```bash
   ip netns exec ns2 tc qdisc add dev veth23a root netem delay 5ms 2ms 25% \
     loss 0.3% reorder 1% corrupt 0.05%
   ```
2. **验证配置**
   ```bash
   ip netns exec ns2 tc qdisc show dev veth23a
   ```
3. **重复基线测试**  
   - `iperf3` + `ping` 再跑一次，文件命名 `logs/ping_tail_ns5.txt`。  
   - 运行 `nstat -az | grep -E "RetransSegs|InErrors"`.
  
   ```bash
   sudo bash -c '
   # 清理
   pkill -9 iperf 2>/dev/null
   pkill -9 iperf3 2>/dev/null
   fuser -k 5001/tcp 2>/dev/null
   sleep 2

   echo "=== 测试前链路状态 ==="
   ip netns exec ns2 ethtool -S veth23a | head > logs/before_ethtool.txt
   ip netns exec ns3 traceroute -n 10.0.12.1 > logs/before_traceroute.txt


   # 运行
   mkdir -p logs
   echo "=== 启动服务器 (ns1:10.0.12.1) ==="
   ip netns exec ns1 iperf -s &
   SERVER_PID=$!
   sleep 3
   
   echo "=== 带宽测试 (ns3 -> ns1) ==="
   # 重要：连接 ns1 的 IP，不是 ns3 自己的 IP
   ip netns exec ns3 iperf -c 10.0.12.1 -t 20 -i 2
   
   echo "=== Ping测试 (ns5 -> ns1) ==="
   ip netns exec ns5 ping -c 50 -i 0.2 10.0.12.1 > logs/ping_baseline_ns5.txt
   
   nstat -az | grep -E "RetransSegs|InErrors

   echo "=== 测试后链路状态 ==="
   ip netns exec ns2 ethtool -S veth23a | head > logs/after_ethtool.txt
   ip netns exec ns3 traceroute -n 10.0.12.1 > logs/after_traceroute.txt
   
   ```
   
5. **采集链路信息**  
   ```bash
   ip netns exec ns2 ethtool -S veth23a | head
   ip netns exec ns3 traceroute -n 10.0.12.1
   ```
6. **可选：引入动态尾部**  
   ```bash
   watch -n 30 'ip netns exec ns2 tc qdisc change dev veth23a root netem delay 5ms 10ms 30% distribution normal'
   ```

## 7. 观测分层清单
- **网络层**：`tc qdisc show`, `ip -s link`, `nstat`, `ethtool -S`, `tcpdump -i veth23a -nn`.
- **系统层**：`ip netns exec <ns> top`, `perf sched latency`.
- **任务层**：iperf3.
- **可选 eBPF**：`bpftool prog`, `sudo ip netns exec ns2 ./tools/flowlatency.bpf`.

## 8. 报告要求
1. 描述拓扑、注入参数、命名空间角色。
2. 提供至少一张 RTT 百分位图或表（可用 `python -m pandas` 生成）。
   
   ```bash
   python3 rtt_handler.py
   ```
   
4. 对选定计算场景给出“无 tail vs 有 tail”的 p99/完成时间对比及原因分析。
5. 附上关键命令与输出（`ipc`, `tc`, `spark`/`hadoop`/`torch` 日志摘要）。
6. 说明一次成功往返测试的命令与结果。

## 9. 清理与回滚
```bash
ip netns exec ns2 tc qdisc del dev veth23a root || true
sudo bash experiments/01/ns.sh down
```
