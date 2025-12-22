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
   # 清理所有 iperf 相关进程
   sudo pkill -9 iperf3
   sudo pkill -9 iperf

   # 清理可能占用的端口
   sudo fuser -k 5201/tcp 2>/dev/null
   sudo fuser -k 5202/tcp 2>/dev/null
   sudo fuser -k 5203/tcp 2>/dev/null

   # 等待清理完成
   sleep 2
   ```
   
   ```bash
   ip netns exec ns1 iperf3 -s -D
   ip netns exec ns3 iperf3 -c 10.0.23.2 -t 20 -i 2
   ip netns exec ns5 ping -c 50 -i 0.2 10.0.12.1 > logs/ping_baseline_ns5.txt
   ```
3. **记录统计**  
   - 计算 p50/p90/p99 RTT。  
   - 保存 `iperf3` 带宽和重传数。
4. **清理临时服务**  
   ```bash
   ip netns exec ns1 pkill iperf3 || true
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
4. **采集链路信息**  
   ```bash
   ip netns exec ns2 ethtool -S veth23a | head
   ip netns exec ns3 traceroute -n 10.0.12.1
   ```
5. **可选：引入动态尾部**  
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
3. 对选定计算场景给出“无 tail vs 有 tail”的 p99/完成时间对比及原因分析。
4. 附上关键命令与输出（`ipc`, `tc`, `spark`/`hadoop`/`torch` 日志摘要）。
5. 说明一次成功往返测试的命令与结果。

## 9. 清理与回滚
```bash
ip netns exec ns2 tc qdisc del dev veth23a root || true
sudo bash experiments/01/ns.sh down
```
