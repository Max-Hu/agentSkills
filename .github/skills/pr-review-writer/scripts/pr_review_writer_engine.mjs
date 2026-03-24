import fs from 'fs';
import path from 'path';

const severityOrder = { critical: 0, high: 1, medium: 2, low: 3 };
const categoryOrder = { 'Jira Alignment': 0, 'Implementation Risk': 1, 'Code Quality': 2, 'Test Gap': 3, 'Reviewer Concern': 4 };
const stopwords = new Set(['a','an','and','are','for','from','the','this','that','with','into','when','during','still','does','not']);
const docExtensions = new Set(['.md', '.txt', '.rst', '.adoc']);
const highRiskPathHints = ['migration', 'schema', 'payment', 'billing', 'auth', 'permission', 'security', 'terraform', 'k8s', 'helm', 'config', 'sql'];
const languageByExtension = { '.py': 'Python', '.java': 'Java' };
const severityEmoji = { critical: '🔴', high: '🟠', medium: '🟡', low: '🟢' };
const severityLabel = { critical: 'Critical', high: 'High', medium: 'Medium', low: 'Low' };

function parseArgs(argv) {
  const result = { input: '', draftPath: '', output: 'markdown', modeUsed: '', promptText: '' };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = argv[i + 1] ?? '';
    if (arg === '--input') {
      result.input = next;
      i += 1;
    } else if (arg === '--draft-path') {
      result.draftPath = next;
      i += 1;
    } else if (arg === '--output') {
      result.output = next;
      i += 1;
    } else if (arg === '--mode-used') {
      result.modeUsed = next;
      i += 1;
    } else if (arg === '--prompt-text') {
      result.promptText = next;
      i += 1;
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  return result;
}

function flattenAdf(node) {
  if (node == null) return '';
  if (typeof node === 'string') return node;
  if (Array.isArray(node)) return node.map(flattenAdf).filter(Boolean).join('\n').trim();
  if (node.type === 'text') return node.text || '';
  const text = flattenAdf(node.content || []);
  if (['paragraph', 'heading', 'listItem'].includes(node.type)) return text;
  if (['bulletList', 'orderedList'].includes(node.type)) {
    return text.split(/\r?\n/).filter(Boolean).map((line) => `- ${line}`).join('\n');
  }
  return text;
}

function summarizeJiraIssue(issue) {
  const fields = issue?.fields || {};
  const comments = issue?.comments || fields?.comment?.comments || [];
  return {
    key: issue?.key || 'UNKNOWN',
    title: fields.summary || 'No summary',
    status: fields.status?.name || 'Unknown',
    priority: fields.priority?.name || 'Unknown',
    assignee: fields.assignee?.displayName || 'Unassigned',
    description_text: flattenAdf(fields.description),
    comment_excerpts: comments.slice(0, 6).map((comment) => {
      const author = comment?.user?.login || comment?.author?.displayName || 'unknown';
      const body = flattenAdf(comment?.body || '').replace(/\s+/g, ' ').trim();
      return body ? `${author}: ${body.length > 160 ? `${body.slice(0, 157).trimEnd()}...` : body}` : null;
    }).filter(Boolean),
  };
}

function tokenize(text) {
  return new Set((String(text || '').toLowerCase().match(/[a-z0-9]+/g) || [])
    .filter((token) => token.length > 2 && !stopwords.has(token) && !/^\d+$/.test(token)));
}

function isTestFile(filePath) {
  return /(^|\/)(tests?|__tests__)\/|(_test|_spec)\.|(\.test\.|\.spec\.)/i.test(filePath.replace(/\\/g, '/'));
}

function isDocFile(filePath) {
  const normalized = filePath.replace(/\\/g, '/').toLowerCase();
  return docExtensions.has(path.extname(filePath).toLowerCase()) || normalized.startsWith('docs/') || normalized.startsWith('doc/');
}

function patchExcerpt(patch = '') {
  const lines = [];
  for (const line of String(patch).split(/\r?\n/)) {
    if (line.startsWith('+++') || line.startsWith('---')) continue;
    if (line.startsWith('@@') || line.startsWith('+') || line.startsWith('-')) lines.push(line);
    if (lines.length >= 16) break;
  }
  const text = lines.join('\n').trim();
  return text.length > 1400 ? `${text.slice(0, 1397).trimEnd()}...` : text;
}

function codeFindings(fileEntry) {
  const findings = [];
  const lowered = fileEntry.patch_excerpt.toLowerCase();
  if (lowered.includes('todo')) findings.push(`${fileEntry.filename}: diff still contains a TODO marker, so the implementation may not be production-complete.`);
  if (fileEntry.patch_excerpt.includes('except Exception')) findings.push(`${fileEntry.filename}: broad \`except Exception\` handling may hide failure causes and make retries harder to reason about.`);
  if (/def\s+\w+\([^)]*=\[\]/.test(fileEntry.patch_excerpt)) findings.push(`${fileEntry.filename}: mutable default list argument can leak state across calls.`);
  if (lowered.includes('logger.info') && lowered.includes('token')) findings.push(`${fileEntry.filename}: logging token-related state deserves a quick review to avoid leaking sensitive request context.`);
  return findings;
}

function commentExcerpts(comments, limit = 6) {
  return (comments || []).slice(0, limit).map((comment) => {
    const author = comment?.user?.login || comment?.author?.displayName || 'unknown';
    const body = String(comment?.body || '').replace(/\s+/g, ' ').trim();
    if (!body) return null;
    return `${author}: ${body.length > 160 ? `${body.slice(0, 157).trimEnd()}...` : body}`;
  }).filter(Boolean);
}

function diffEvidence(files) {
  const evidenceFiles = [];
  const codeFiles = [];
  const testFiles = [];
  const docFiles = [];
  const patchFiles = [];
  const findings = [];
  const languages = new Set();

  for (const item of files || []) {
    const ext = path.extname(item.filename || '').toLowerCase();
    const language = languageByExtension[ext] || 'Unknown';
    if (language !== 'Unknown') languages.add(language);
    const entry = {
      filename: item.filename || '',
      status: item.status || 'modified',
      additions: Number(item.additions || 0),
      deletions: Number(item.deletions || 0),
      language,
      is_test: isTestFile(item.filename || ''),
      is_doc: isDocFile(item.filename || ''),
      has_patch: Boolean(item.patch),
      patch_excerpt: patchExcerpt(item.patch || ''),
    };
    evidenceFiles.push(entry);
    if (entry.is_test) testFiles.push(entry);
    else if (entry.is_doc) docFiles.push(entry);
    else codeFiles.push(entry);
    if (entry.has_patch) {
      patchFiles.push(entry);
      findings.push(...codeFindings(entry));
    }
  }

  const languageList = [...languages].sort();
  const evidence = [];
  if (languageList.length) evidence.push(`Detected code languages in changed files: ${languageList.join(', ')}.`);
  if (patchFiles.length) evidence.push(`Inline patch excerpts are available for ${patchFiles.length} file(s): ${patchFiles.slice(0, 4).map((item) => item.filename).join(', ')}.`);
  else evidence.push('No inline patch excerpt was returned by GitHub for code-level inspection.');
  if (codeFiles.length) evidence.push(`Changed production files: ${codeFiles.slice(0, 5).map((item) => item.filename).join(', ')}.`);
  if (testFiles.length) evidence.push(`Changed test files: ${testFiles.slice(0, 4).map((item) => item.filename).join(', ')}.`);
  if (docFiles.length) evidence.push(`Changed documentation files: ${docFiles.slice(0, 3).map((item) => item.filename).join(', ')}.`);

  const positives = [];
  if (testFiles.length) positives.push(`Test files changed: ${testFiles.slice(0, 3).map((item) => item.filename).join(', ')}.`);
  if (docFiles.length) positives.push(`Documentation/runbook updates present: ${docFiles.slice(0, 2).map((item) => item.filename).join(', ')}.`);
  if (patchFiles.length) positives.push(`Diff evidence captured patch excerpts for ${patchFiles.length} file(s).`);

  return {
    languages: languageList,
    files: evidenceFiles,
    code_files: codeFiles,
    test_files: testFiles,
    doc_files: docFiles,
    patch_files: patchFiles,
    code_evidence: evidence,
    code_findings: findings,
    positives,
    questions: patchFiles.slice(0, 3).map((item) => `What changed semantically in ${item.filename} and how is it validated?`),
  };
}

function testSuggestions(languages, codeFiles, testFiles, riskyPaths) {
  const suggestions = [];
  const add = (item) => {
    if (item && !suggestions.includes(item)) suggestions.push(item);
  };
  if (codeFiles.length && !testFiles.length) add('Add targeted regression tests for the changed production paths because no test files changed.');
  if (languages.includes('Python')) add('Add Python coverage for changed branches, error handling, and repeated-call behavior visible in the diff.');
  if (languages.includes('Java')) add('Add Java coverage for changed branches, exception handling, and state transitions visible in the diff.');
  if (riskyPaths.some((item) => /payment|billing/.test(item.toLowerCase()))) add('Add an integration test covering duplicate events, retries, idempotency, and downstream side effects for payment-related paths.');
  if (riskyPaths.some((item) => /migration|sql|schema/.test(item.toLowerCase()))) add('Add a migration compatibility test covering existing rows, rollout, rollback, and read/write compatibility.');
  if (riskyPaths.some((item) => /auth|permission|security/.test(item.toLowerCase()))) add('Add authorization and negative-path tests proving unsafe callers are rejected.');
  if (!suggestions.length && codeFiles.length) add('Add focused unit tests around changed methods plus one end-to-end regression covering the primary business flow.');
  return suggestions.slice(0, 8);
}

function newFinding(severity, category, title, details, suggestedFix, evidenceRefs) {
  return { severity, category, title, summary: title, details, suggested_fix: suggestedFix, evidence_refs: evidenceRefs };
}

function buildFindings({ jiraKeys, alignmentFindings, riskFindings, codeFindingsList, testFindings, issueCommentExcerpts, reviewCommentExcerpts }) {
  const findings = [];
  for (const message of alignmentFindings) {
    if (message.startsWith('No obvious')) continue;
    if (message.startsWith('No Jira key')) findings.push(newFinding('high', 'Jira Alignment', 'PR is not traceable to a Jira issue', message, 'Add the Jira key to the PR title, body, branch name, or commits and verify the implementation scope matches that issue.', jiraKeys));
    else if (message.startsWith('Multiple Jira keys')) findings.push(newFinding('medium', 'Jira Alignment', 'Multiple Jira issues are linked to one PR', message, 'Confirm whether the PR intentionally spans multiple Jira issues; otherwise split the work or document the scope boundary.', jiraKeys));
    else if (message.includes('weak term overlap')) findings.push(newFinding('medium', 'Jira Alignment', 'PR title and Jira intent look weakly aligned', message, 'Clarify the PR title and description so reviewers can map the implementation to the Jira intent without inference.', jiraKeys));
    else findings.push(newFinding('medium', 'Jira Alignment', 'Jira context is incomplete', message, 'Load or document the missing Jira context before approving the change.', jiraKeys));
  }

  for (const message of riskFindings) {
    if (message.startsWith('No obvious')) continue;
    if (message.startsWith('Large change set')) findings.push(newFinding('medium', 'Implementation Risk', 'Large change set increases review surface', message, 'Break the PR into smaller units or add stronger reviewer guidance and focused regression coverage.', [message]));
    else if (message.startsWith('Risky paths touched')) findings.push(newFinding('high', 'Implementation Risk', 'High-risk production paths were modified', message, 'Add targeted validation for the risky paths and confirm rollout, rollback, and failure handling.', [message]));
    else if (message.startsWith('Production code changed without')) findings.push(newFinding('high', 'Implementation Risk', 'Production code changed without matching tests', message, 'Add or update regression tests that exercise the changed production paths before merge.', [message]));
    else findings.push(newFinding('medium', 'Implementation Risk', 'PR carries implementation risk', message, 'Document the operational risk and add missing validation before approval.', [message]));
  }

  for (const message of codeFindingsList) {
    const [prefix, detail = message] = message.split(': ', 2);
    let fix = 'Tighten the implementation and add a focused regression test for this code path.';
    let severity = 'medium';
    if (message.includes('except Exception')) {
      fix = 'Catch the narrowest expected exception type and add logging or error propagation that preserves failure context.';
      severity = 'high';
    } else if (message.includes('mutable default')) {
      fix = 'Replace the mutable default with None, then initialize the collection inside the function body.';
      severity = 'high';
    } else if (message.includes('TODO marker')) {
      fix = 'Resolve the TODO before merge or convert it into a tracked follow-up issue with explicit scope and owner.';
    } else if (message.includes('token-related')) {
      fix = 'Review the log statement and avoid logging sensitive request context or tokens.';
    }
    findings.push(newFinding(severity, 'Code Quality', detail, message, fix, [prefix]));
  }

  for (const message of testFindings) {
    if (message.startsWith('Observed') || message.startsWith('No executable')) continue;
    if (message.startsWith('Code changed without')) findings.push(newFinding('high', 'Test Gap', 'Test coverage is missing for changed implementation', message, 'Add tests that cover the modified production behavior before merging.', [message]));
    else if (message.startsWith('Test Gap: ')) findings.push(newFinding('medium', 'Test Gap', message.slice(10), message, `Implement: ${message.slice(10)}`, [message]));
    else findings.push(newFinding('medium', 'Test Gap', message, message, 'Add the missing regression coverage described by this gap before approval.', [message]));
  }

  for (const excerpt of reviewCommentExcerpts.slice(0, 4)) findings.push(newFinding('medium', 'Reviewer Concern', 'Reviewer raised an unresolved question', excerpt, 'Address the reviewer concern directly in code, tests, or PR discussion before approval.', [excerpt]));
  for (const excerpt of issueCommentExcerpts.slice(0, 2)) findings.push(newFinding('medium', 'Reviewer Concern', 'Issue comment adds unresolved acceptance concern', excerpt, 'Close the acceptance concern explicitly in the PR description, code, or tests.', [excerpt]));

  const detailed = findings.sort((left, right) => {
    const leftKey = [severityOrder[left.severity], categoryOrder[left.category] ?? 99, left.title];
    const rightKey = [severityOrder[right.severity], categoryOrder[right.category] ?? 99, right.title];
    return leftKey[0] - rightKey[0] || leftKey[1] - rightKey[1] || leftKey[2].localeCompare(rightKey[2]);
  });
  const summary = detailed.map((item) => ({
    severity: item.severity,
    category: item.category,
    title: item.title,
    summary: item.summary,
    suggested_fix: item.suggested_fix,
    evidence_refs: item.evidence_refs,
  }));
  return { detailed, summary };
}

function evidenceSources(reportPrUrl, pull, jiraIssues, commits, issueComments, reviewComments, diff) {
  return {
    pr: {
      url: reportPrUrl,
      title: pull?.title || 'Unknown PR',
      author: pull?.user?.login || 'unknown',
      head_ref: pull?.head?.ref || '',
      base_ref: pull?.base?.ref || '',
      changed_files: diff.files.length || Number(pull?.changed_files || 0),
      churn: Number(pull?.additions || 0) + Number(pull?.deletions || 0),
    },
    jira: jiraIssues.map((issue) => ({
      key: issue.key,
      title: issue.title,
      status: issue.status,
      priority: issue.priority,
      assignee: issue.assignee,
      description_available: Boolean(issue.description_text),
      comment_count: issue.comment_excerpts.length,
    })),
    commits: (commits || []).slice(0, 10).map((commit) => commit?.commit?.message || ''),
    comments: {
      issue_comments: commentExcerpts(issueComments, 6),
      review_comments: commentExcerpts(reviewComments, 6),
    },
    files: diff.files.slice(0, 20).map((fileEntry) => ({
      filename: fileEntry.filename,
      language: fileEntry.language,
      is_test: fileEntry.is_test,
      is_doc: fileEntry.is_doc,
      has_patch: fileEntry.has_patch,
    })),
  };
}

function analyzeBundle(bundle, modeUsed, promptText) {
  const pull = bundle.pull || {};
  const files = bundle.files || [];
  const commits = bundle.commits || [];
  const issueComments = bundle.issue_comments || [];
  const reviewComments = bundle.review_comments || [];
  const jiraKeys = bundle.jira_keys || Object.keys(bundle.jira_issues || {});
  const jiraIssues = jiraKeys.filter((key) => bundle.jira_issues?.[key]).map((key) => summarizeJiraIssue(bundle.jira_issues[key]));
  const diff = diffEvidence(files);
  const riskyPaths = files.map((item) => item.filename || '').filter((filePath) => highRiskPathHints.some((hint) => filePath.toLowerCase().includes(hint)));
  const churn = Number(pull.additions || 0) + Number(pull.deletions || 0);

  const alignmentFindings = [];
  if (!jiraKeys.length) alignmentFindings.push('No Jira key was found in the PR title, branch name, body, or commit messages.');
  else if (jiraKeys.length > 1) alignmentFindings.push(`Multiple Jira keys were detected: ${jiraKeys.join(', ')}.`);
  if (jiraKeys.length && !jiraIssues.length) alignmentFindings.push('Jira keys were detected, but no Jira issue details were loaded.');

  const titleTokens = tokenize(pull.title || '');
  for (const issue of jiraIssues) {
    const jiraTokens = tokenize(`${issue.title} ${issue.description_text} ${issue.comment_excerpts.join(' ')}`);
    const overlap = [...titleTokens].filter((token) => jiraTokens.has(token));
    if (overlap.length < 2) alignmentFindings.push(`${issue.key} has weak term overlap with the PR title; verify the implementation scope manually.`);
    if (!issue.description_text) alignmentFindings.push(`${issue.key} does not expose a Jira description; confirm intent from Jira comments or linked docs.`);
  }

  const positives = [];
  if (jiraKeys.length) positives.push(`Detected Jira link(s): ${jiraKeys.join(', ')}.`);
  positives.push(...diff.positives.filter((item) => !positives.includes(item)));
  if (!positives.length) positives.push('No positive signals were detected automatically.');

  const riskFindings = [];
  let riskLevel = 'Low';
  if (pull.draft) { riskFindings.push('The PR is still marked as draft.'); riskLevel = 'Medium'; }
  if (churn >= 600 || files.length > 15) { riskFindings.push(`Large change set: ${files.length} files and ${churn} lines of churn.`); riskLevel = 'High'; }
  if (riskyPaths.length) { riskFindings.push(`Risky paths touched: ${riskyPaths.join(', ')}.`); riskLevel = 'High'; }
  if (diff.code_files.length && !diff.test_files.length) { riskFindings.push('Production code changed without matching test file updates.'); if (riskLevel === 'Low') riskLevel = 'High'; }
  if (!riskFindings.length) riskFindings.push('No obvious high-risk path or unusually large churn was detected from metadata alone.');

  const testFindings = [];
  if (diff.code_files.length && !diff.test_files.length) testFindings.push('Code changed without any matching test file updates.');
  else if (diff.test_files.length) testFindings.push(`Observed ${diff.test_files.length} test file change(s) alongside the implementation.`);
  else testFindings.push('No executable code changes were detected.');
  for (const suggestion of testSuggestions(diff.languages, diff.code_files, diff.test_files, riskyPaths)) {
    testFindings.push(`Test Gap: ${suggestion}`);
  }

  const issueCommentExcerpts = commentExcerpts(issueComments, 6);
  const reviewCommentExcerpts = commentExcerpts(reviewComments, 6);
  const openQuestions = [...diff.questions, ...reviewCommentExcerpts, ...issueCommentExcerpts];
  if (!openQuestions.length) openQuestions.push('No reviewer or issue comments were captured.');

  let recommendation = 'Approve with normal review';
  if (!jiraKeys.length || (riskLevel === 'High' && !diff.test_files.length)) recommendation = 'Request changes';
  else if (['High', 'Medium'].includes(riskLevel) || alignmentFindings.length) recommendation = 'Needs clarification';

  const structured = buildFindings({
    jiraKeys,
    alignmentFindings,
    riskFindings,
    codeFindingsList: diff.code_findings.length ? diff.code_findings : ['No concrete inline code findings were detected automatically.'],
    testFindings,
    issueCommentExcerpts,
    reviewCommentExcerpts,
  });

  return {
    generated_at: new Date().toISOString(),
    mode_used: modeUsed,
    prompt_text: promptText || null,
    pr_url: bundle.pr_url || pull.html_url,
    pull: {
      number: pull.number,
      title: pull.title || 'Unknown PR',
      author: pull.user?.login || 'unknown',
      state: pull.state || 'unknown',
      draft: Boolean(pull.draft),
      head_ref: pull.head?.ref || '',
      base_ref: pull.base?.ref || '',
      changed_files: files.length || Number(pull.changed_files || 0),
      additions: Number(pull.additions || 0),
      deletions: Number(pull.deletions || 0),
      churn,
      sample_files: files.slice(0, 5).map((item) => item.filename || ''),
      commit_count: commits.length,
      languages: diff.languages,
    },
    jira_keys: jiraKeys,
    jira_issues: jiraIssues,
    evidence: {
      files: diff.files.slice(0, 40),
      commit_messages: commits.slice(0, 10).map((commit) => commit?.commit?.message || ''),
      issue_comments: issueCommentExcerpts,
      review_comments: reviewCommentExcerpts,
      sources: evidenceSources(bundle.pr_url || pull.html_url, pull, jiraIssues, commits, issueComments, reviewComments, diff),
    },
    analysis: {
      positives,
      alignment_findings: alignmentFindings.length ? alignmentFindings : ['No obvious Jira alignment gaps were detected from the available metadata.'],
      risk_level: riskLevel,
      risk_findings: riskFindings,
      code_evidence: diff.code_evidence,
      code_findings: diff.code_findings.length ? diff.code_findings : ['No concrete inline code findings were detected automatically.'],
      test_findings: testFindings,
      open_questions: openQuestions.slice(0, 8),
      recommendation,
      findings_summary: structured.summary,
      detailed_findings: structured.detailed,
    },
  };
}

function renderMarkdown(report) {
  const pull = report.pull;
  const analysis = report.analysis;
  const lines = [
    '# PR Review',
    '',
    '## Review Scope',
    `- PR: ${report.pr_url}`,
    `- Mode: ${report.mode_used}`,
    `- Generated at: ${report.generated_at}`,
    `- Title: ${pull.title}`,
    `- Author: ${pull.author}`,
    `- Branches: \`${pull.head_ref}\` -> \`${pull.base_ref}\``,
    `- Size: ${pull.changed_files} files, +${pull.additions} / -${pull.deletions} (${pull.churn} lines)`,
  ];
  if (report.prompt_text) lines.push(`- Request: ${report.prompt_text}`);
  if (report.orchestration) lines.push(`- Subagent plan: ${report.orchestration.use_subagents ? 'enabled' : 'local-only'}`);
  lines.push('', '## Findings Summary');
  if (!analysis.findings_summary.length) {
    lines.push('- 🟢 No high-severity findings were detected automatically.');
  } else {
    for (const item of analysis.findings_summary) {
      lines.push(`- ${severityEmoji[item.severity]} **${severityLabel[item.severity]}** [${item.category}] ${item.title}`);
    }
  }
  lines.push('', '## Detailed Analysis And Suggested Fixes');
  if (!analysis.detailed_findings.length) {
    lines.push('No actionable findings were detected automatically.');
  } else {
    for (const item of analysis.detailed_findings) {
      lines.push(
        `### ${severityEmoji[item.severity]} ${item.title}`,
        `- Severity: ${severityLabel[item.severity]}`,
        `- Category: ${item.category}`,
        `- Analysis: ${item.details}`,
        `- Suggested change: ${item.suggested_fix}`,
        `- Evidence: ${(item.evidence_refs || []).join(' | ') || 'No direct evidence references captured.'}`,
        '',
      );
    }
  }
  const sources = report.evidence.sources;
  lines.push('## Evidence Sources', '### PR', `- URL: ${sources.pr.url}`, `- Title: ${sources.pr.title}`, `- Author: ${sources.pr.author}`, `- Branches: \`${sources.pr.head_ref}\` -> \`${sources.pr.base_ref}\``, `- Size scanned: ${sources.pr.changed_files} files / ${sources.pr.churn} lines`, '', '### Jira');
  if (sources.jira.length) {
    for (const issue of sources.jira) lines.push(`- \`${issue.key}\`: ${issue.title} (${issue.status}, ${issue.priority}, assignee: ${issue.assignee}, comments scanned: ${issue.comment_count})`);
  } else {
    lines.push('- No Jira issues were loaded.');
  }
  lines.push('', '### Commits');
  if (sources.commits.length) {
    for (const message of sources.commits) lines.push(`- ${message}`);
  } else {
    lines.push('- No commit messages were captured.');
  }
  lines.push('', '### Comments');
  if (sources.comments.review_comments.length) {
    lines.push('- Review comments scanned:');
    for (const item of sources.comments.review_comments) lines.push(`  - ${item}`);
  }
  if (sources.comments.issue_comments.length) {
    lines.push('- Issue comments scanned:');
    for (const item of sources.comments.issue_comments) lines.push(`  - ${item}`);
  }
  if (!sources.comments.review_comments.length && !sources.comments.issue_comments.length) lines.push('- No PR comments were captured.');
  lines.push('', '### Diff Files');
  if (sources.files.length) {
    for (const fileEntry of sources.files) {
      const kind = fileEntry.is_test ? 'test' : fileEntry.is_doc ? 'doc' : 'code';
      const patchStatus = fileEntry.has_patch ? 'patch' : 'metadata-only';
      lines.push(`- ${fileEntry.filename} (${kind}, ${fileEntry.language}, ${patchStatus})`);
    }
  } else {
    lines.push('- No changed files were captured.');
  }
  lines.push('', '## Recommendation', `- ${analysis.recommendation}`, '', '## Positive Signals');
  for (const item of analysis.positives) lines.push(`- ${item}`);
  return `${lines.join('\n').trim()}\n`;
}

function writeDraft(markdown, draftPath, prUrl, sourceMode) {
  fs.mkdirSync(path.dirname(draftPath), { recursive: true });
  fs.writeFileSync(draftPath, markdown, 'utf8');
  return {
    draft_path: path.resolve(draftPath),
    pr_url: prUrl,
    generated_at: new Date().toISOString(),
    source_mode: sourceMode,
  };
}

try {
  const args = parseArgs(process.argv);
  if (!args.input) throw new Error('Provide --input with a combined bundle JSON file.');
  const bundle = JSON.parse(fs.readFileSync(args.input, 'utf8'));
  const report = analyzeBundle(bundle, args.modeUsed || bundle.mode_used || 'unknown', args.promptText || bundle.prompt_text || '');
  const markdown = renderMarkdown(report);
  if (args.draftPath) report.draft = writeDraft(markdown, args.draftPath, report.pr_url, report.mode_used);
  if (args.output === 'json') {
    process.stdout.write(JSON.stringify(report, null, 2));
  } else {
    process.stdout.write(markdown);
  }
} catch (error) {
  console.error(`error: ${error.message}`);
  process.exit(1);
}
