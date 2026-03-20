在 VS Code 的 Copilot Chat / Agent Mode 中，输入一个 GitHub PR 链接，Copilot 自动调用你提供的 skill，拉取 PR 信息和关联 Jira 信息，然后输出固定格式的 review 建议。

这个方向是合理的，因为 VS Code 的 agent mode 本来就支持多步任务、读代码、提议修改，并且可以调用外部工具；GitHub 官方文档也明确区分了 IDE 里的 agent mode 和 GitHub 上跑在 Actions 环境里的 coding agent，你这里要做的是前者，不是后者。

最小实现方案

我建议你只做这三层：

第一层：Copilot 入口

用户在 VS Code chat 或 agent mode 里输入类似：

Review this PR: https://github.com/org/repo/pull/123
Focus on risk, Jira alignment, and missing tests.

这里不需要你自己重做聊天 UI，直接复用 GitHub Copilot in VS Code 的 chat / agent mode。VS Code 官方文档说明，Copilot 在 agent mode 下会自主决定步骤，并可使用工具完成任务。

第二层：你提供的 Agent Skills / Tools

POC 只做 3 个 tool 就够了：

get_pr_context
输入：prUrl
输出：PR title、description、changed files、diff summary、commits、comments、author

extract_jira_key
输入：PR title、branch name、commit messages、PR body
输出：一个或多个 Jira Key

get_jira_context
输入：Jira Key
输出：summary、description、status、acceptance criteria、assignee、priority

这三个 tool 里，前两个面向 GitHub，后一个面向 Jira。这样最小闭环已经形成了。

第三层：review prompt / 输出模板

最后由 Copilot 基于这些 tool 返回的数据，按固定 Markdown 模板输出 review。