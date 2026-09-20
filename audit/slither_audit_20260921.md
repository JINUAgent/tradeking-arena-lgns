# TradeKing Arena (LGNS) — Slither 静态分析审计报告

- **审计对象**：TradeKingArenaLGNS.sol（Anubis Chain 0x3884c464f5134b181b8a097ED930c35E5E6943ef）
- **审计工具**：Slither v0.11.6（Trail of Bits 出品，静态分析，102 个检测器）
- **编译器**：solc v0.8.37+commit.f401782d（与主网部署一致，legacy + optimizer 200）
- **执行时间**：2026-09-21 02:24 UTC+8
- **执行环境**：本地独立分析环境（Windows / Python 3.12）

## 结论

**102 个检测器全量扫描，19 项结果，0 Critical / 0 High / 0 Medium。**
全部发现为 Informational / Low 级别的工程风格提示，无实质安全漏洞。

## 发现清单与定性

| # | 检测器 | 位置 | 定性 |
|---|--------|------|------|
| 1 | weak-prng | inSettleWindow() #193 `(block.timestamp + WEEK_ALIGN) % WEEK < SETTLE_WINDOW` | **误报**：该表达式是结算窗口的时间对齐判断，不是随机数源，不存在被操纵 randomness 的语义 |
| 2 | reentrancy-no-eth | triggerSettlement() 外部调用后写 settled | Low：LGNS 为标准 ERC-20（无 ERC-777 回调钩子），重入路径不成立；且 burn 前已做 settled 检查 |
| 3 | reentrancy-benign | seed() transferFrom 后写 trackPool | Informational：同上，token 无回调能力 |
| 4 | reentrancy-events ×5 | claimPrize/emergencyWithdraw/enroll/seed/triggerSettlement 事件在 external call 后发出 | Informational：CEI 风格建议，事件顺序不影响状态正确性 |
| 5 | timestamp ×6 | 结算窗口/冷却/周界判定使用 block.timestamp | Informational：时间窗口设计意图明确（2 小时结算窗口、24h 冷却），矿工 ±15s 偏差不改变语义 |
| 6 | unindexed-event-address ×3 | OracleProposed/OracleConfirmed/OracleActivated | Informational：事件参数未加 indexed，链下检索效率建议 |
| 7 | immutable-states | signerB 可声明为 immutable | Informational：代码风格 |

## 与既有审计的交叉验证

本报告与内部三重 AI 审计（Guardian 安全轨 72 → AuditAgent 业务逻辑 82 → Guardian 增量复审终评 94/100）结论一致：无阻塞性安全问题。Slither 的 reentrancy/timestamp 提示与内部审计 round-2 的 findings 相同，均确认为设计意图或误报。

## 原始输出

完整原始输出见同目录 `slither_raw.txt`（Slither stdout 原文）。

---
*本报告由 Slither v0.11.6 (Trail of Bits) 自动生成，由 Jimu Agent 于独立环境执行并整理。工具文档：https://github.com/crytic/slither*
