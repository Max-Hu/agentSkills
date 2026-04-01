# PR Jira Review

这个 skill 用来在 VS Code Chat 里审查一个 GitHub PR，并结合 Jira 上下文生成 review。
当前启用的是 Java / Spring 专家审查能力。

## 需要哪些配置

### 只做演示或离线 mock

不需要任何配置。

### 需要真实 GitHub PR 数据

建议配置：

- `GITHUB_TOKEN`

如果是 GitHub Enterprise，还需要：

- `GITHUB_API_BASE_URL`

### 需要真实 Jira 数据

还需要配置：

- `JIRA_BASE_URL`
- `JIRA_USERNAME`
- `JIRA_PASSWORD`

## 在 VS Code Chat 里怎么用

最常用的是直接在 Chat 里提：

```text
用 $pr-jira-review 审查这个 PR：
https://github.com/acme/payments-service/pull/123
```

如果你想强调要真实数据：

```text
用 $pr-jira-review 用真实 GitHub 和 Jira 数据审查这个 PR：
https://github.com/acme/payments-service/pull/123
```

如果你只想离线演示：

```text
用 $pr-jira-review 用 mock 模式演示审查一个 PR
```

如果你还想让它发布 review comment，可以继续说：

```text
把刚才生成的 review 发布回这个 PR
```

## 你会得到什么

通常会得到这些结果：

- PR 概要
- Jira 对齐情况
- Java / Spring 代码风险
- 缺失测试建议
- 审查结论，例如 `Needs clarification` 或 `Request changes`
- 一个可编辑的 Markdown draft

## 当前审查边界

当前代码级审查主要覆盖 Java 生态文件：

- `.java`
- Spring 配置文件
- `src/main/resources` 下的运行时配置
- `pom.xml` / `build.gradle`
- 日志配置文件

非 Java 文件仍会参与风险和上下文汇总，但不会产出 Java 专家型代码 finding。
