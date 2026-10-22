## Summary

<!-- What does this PR change and why? -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [ ] Documentation
- [ ] Refactor / chore

## 公共契约变更（勾中任意一项，必须先在群里通知）

- [ ] 接口变化（URL / 字段 / 状态码 / 错误码 / 分页）
- [ ] 表结构变化（新增 `00N_*.sql` 迁移）
- [ ] 以上都没有

勾中前两项时，把群里发出的通知贴在这里。模板见 `docs/team/01-接口与数据库约定.md` 第 2.3 节。

```text
【接口变更】<接口名>
影响方：<前端 C / 数据库 D / 测试 E / 全部>
变更前：<METHOD /path，字段 a,b,c>
变更后：<METHOD /path，字段 a,b,c'，新增 d>
兼容性：破坏性 / 向后兼容
PR：#<编号>
生效：<合并后立即 / 随下个版本发布>
```

## Test plan

<!-- How did you verify this? Include commands run (e.g. `make all`). -->

- [ ] `make all` passes locally
- [ ] Added/updated tests

## Checklist

- [ ] Updated `CHANGELOG.md` (if user-facing)
- [ ] README / docs updated (if needed)
