# TableLite 项目文档

```
docs/
├── README.md            本文件
├── roadmap.md           实现阶段划分、验收标准、工作量估算
└── tech-designs/        技术设计（实现细节）
```

| 想知道什么 | 去哪看 |
| --- | --- |
| 这个工具做什么、不做什么 | [`../specs/00-scope.md`](../specs/00-scope.md) |
| 界面长什么样、怎么操作 | [`../specs/`](../specs/README.md) |
| 代码怎么组织、某块怎么实现 | [`tech-designs/`](tech-designs/README.md) |
| 先做哪一块、做到什么程度算完成 | [`roadmap.md`](roadmap.md) |
| 还没定的事情 | [`tech-designs/13-open-questions.md`](tech-designs/13-open-questions.md) |

## 文档职责

- **`specs/`** —— 需求设计。描述用户能看到、能操作、能预期的东西。不含代码、类名、库选型、SQL 语句、文件路径。
- **`docs/tech-designs/`** —— 技术设计。描述怎么实现：架构、数据结构、接口、算法、存储格式、构建方式。

改动流程：

1. 需求变化 → 先改 `specs/`
2. 评估 `docs/tech-designs/` 的连带影响并同步修改
3. 两者都改完再动代码

如果发现 `specs/` 里混进了实现细节，把它挪到 `docs/tech-designs/`；反之亦然。
