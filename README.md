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

# Confluence Knowledge QA

这个 skill 用来在 VS Code Chat 里加载一个或多个 Confluence 页面，并在当前会话里基于这些页面持续回答问题。
它会维护一个本地 session manifest 和页面缓存，所以你后续追问时不需要每次重新贴链接。

## 需要哪些配置

### 只做演示或离线 mock

不需要任何配置。

### 需要真实 Confluence 数据

需要配置：

- `CONFLUENCE_API_BASE_URL`
- `CONFLUENCE_USERNAME`
- `CONFLUENCE_PASSWORD`

`CONFLUENCE_API_BASE_URL` 要填 Confluence REST API 根地址，例如：

```text
https://abc.com/confluence/rest/api
```

如果是 Confluence Cloud，`CONFLUENCE_PASSWORD` 可以放 API token。

## 在 VS Code Chat 里怎么用

最常用的是直接在 Chat 里提：

```text
用 $confluence-knowledge-qa 加载这个 Confluence 页面，并总结部署步骤：
https://abc.com/confluence/pages/viewpage.action?pageId=1001
```

如果你想一次加载多个页面并提问：

```text
用 $confluence-knowledge-qa 加载这两个页面，并回答事故处理流程有哪些变化：
https://abc.com/confluence/pages/viewpage.action?pageId=1001
https://abc.com/confluence/display/ENG/Incident+Guide?pageId=1002
```

如果你想在当前会话里继续追加页面：

```text
用 $confluence-knowledge-qa 把这个页面也加入当前上下文，并判断它是否改变了回滚策略：
https://abc.com/confluence/pages/viewpage.action?pageId=1003
```

如果你想基于已经加载的页面继续追问：

```text
继续用当前加载的 Confluence 页面回答：上线前需要哪些检查项？
```

如果你想强制刷新当前会话缓存：

```text
用 $confluence-knowledge-qa 刷新当前 Confluence 上下文，然后重新回答刚才的问题
```

如果你想替换当前页面集合：

```text
用 $confluence-knowledge-qa 只保留这个页面作为当前上下文：
https://abc.com/confluence/pages/viewpage.action?pageId=1002
```

如果你想清空当前上下文：

```text
用 $confluence-knowledge-qa 清空当前 Confluence 上下文
```

## 你会得到什么

通常会得到这些结果：

- 页面标题、链接和版本信息
- 按标题拆分的内容摘要
- 基于当前已加载页面的问答结果
- 引用到的页面和章节路径

## 会话行为说明

- 默认会把新页面追加到当前会话上下文
- 如果你不再贴链接，它会复用当前已加载的页面集合
- 只有在你明确要求刷新时，才会重新抓取已缓存的页面
- 如果你明确说“替换”或“重置”，它会用新的页面集合覆盖旧上下文
