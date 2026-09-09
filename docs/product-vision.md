# Reviewrr product vision

Reviewrr is a focused workspace for understanding and reviewing pull requests, with AI available
when a reviewer needs deeper context. It is built around a simple belief: code may be cheap to
produce, but understanding it is still skilled engineering work.

## The problem

AI-assisted development increases the amount of code teams need to evaluate. The common workflow is
still organized around repositories, so a reviewer has to remember which repositories contain work,
open them one at a time, and reconstruct the state of each pull request. That makes review feel like
navigation and administration instead of careful technical judgment.

Reviewrr changes the starting point to the reviewer and the pull requests that need attention. The
repository remains important, but it becomes context for the PR rather than the product's primary
navigation model.

## Positioning

Reviewrr is the PR-first workspace for engineering teams: a better place to understand a change,
question its assumptions, discuss it with teammates, and decide whether it is ready. Its short
promise is: **review code with context, not just diffs.**

The product is not trying to be an automated code-review bot. AI helps the reviewer; it does not
replace the reviewer.

## Product philosophy

### Human-first review

The reviewer reads, understands, questions, challenges, comments, discusses, and ultimately approves
or rejects the change. Reviewrr should make those actions clearer and faster while keeping the human
accountable for the decision. GitHub remains the source of truth for published collaboration.

### AI as a quiet companion

AI should appear when a reviewer asks for help, not interrupt with an unsolicited report. Useful
questions include:

- What is this abstraction for, and does the PR description support it?
- Does the code follow an existing pattern?
- Where else is this function or behavior used?
- What could break if this behavior changes?

AI answers are evidence-led and should point to actual code or documentation when possible. Every
answer is read-only until a human explicitly turns it into a draft comment or accepts a suggestion.
Reviewrr never lets AI auto-approve, auto-reject, auto-post comments, auto-modify code, or replace
reviewer judgment.

### Context over generation

The value of AI here is investigation, not code generation. A useful answer may need the PR title and
description, changed files and patches, surrounding code, related symbols, existing implementations,
tests, configuration, documentation, comments, or history. Reviewrr should retrieve only the context
needed for the question and distinguish evidence from assessment.

The current app supplies PR metadata, the changed-file inventory and patches, existing comments,
local drafts, and current analysis to its AI paths. Broader repository-aware retrieval is a roadmap
direction, not a capability to assume today.

## Who Reviewrr serves

- **Senior engineers** need to understand complex changes quickly without losing the important
  architectural details.
- **Tech leads** need a consistent way to maintain quality across several areas of a codebase.
- **Engineering managers** need a useful view of review workload and bottlenecks without turning
  review into surveillance.
- **Staff and principal engineers** need repository and historical context to assess architecture and
  long-term consequences.
- **Junior engineers** need a safe way to ask questions and learn from the reasoning behind review,
  while a human still makes the final call.

## Experience direction

The long-term home screen is a PR inbox: one place where a reviewer can see work requiring attention
across multiple repositories. A row should make triage possible without opening GitHub repository by
repository: repository, author, title, state, age, files and lines changed, CI status, review status,
comments, reviewers, recent activity, and labels.

Opening a row should create a focused review environment. Reviewers should be able to move through
the file tree, read a clean split or unified diff, see related discussion and CI state, mark progress,
and ask a contextual question without leaving the PR. Filters should put important application
changes before tests, generated files, lock files, or formatting-only noise. Comments and replies
should flow back to GitHub, with the reviewer choosing when to submit a review.

Reviewrr's current single-PR workspace already provides the core shape: direct GitHub PR loading,
layered reading order, diff navigation, advisory summaries, line-anchored local drafts, CI details,
an Ask conversation, and explicit review submission. The inbox and smarter file triage are the next
product step.

## UX principles

- **Focus:** keep repository administration out of the review surface.
- **Speed:** make the next file, comment, and question easy to reach.
- **Keyboard-first:** support rapid movement through a large change without forcing mouse travel.
- **Contextual:** show useful surrounding information without flooding the reviewer.
- **Quiet AI:** invoke assistance on demand and keep it out of the way otherwise.
- **Evidence-based:** connect explanations to real code, comments, documentation, and eventually
  history.
- **Lightweight progress:** show what has been reviewed without turning review into a game or a
  performance score.

## Differentiation

Reviewrr is differentiated by six connected choices:

- **PR-first:** the pull request is the primary unit of work.
- **Unified inbox:** one reviewer view across repositories, instead of repository-by-repository
  navigation.
- **Human-first:** humans make the review decision and publish the collaboration.
- **Context-aware:** the diff is a starting point, not the whole explanation.
- **Interactive:** AI answers questions in a conversation rather than emitting a one-shot report.
- **Focused UI:** the workspace is optimized for comprehension and discussion, not Git administration,
  code generation, or project management.

## What we will not build initially

Reviewrr will not start by becoming:

- another IDE;
- another Git client;
- another AI code-review bot;
- another project-management system;
- another GitHub replacement; or
- an autonomous coding agent.

The boundary is intentional: help humans review pull requests better. Integrations with other code
hosts, issue trackers, docs, chat, local repositories, and richer AI investigation can extend that
workspace later, but they should serve the review experience rather than displace it.

## North star

**Reviewrr is the fastest place for an engineer to understand, question, and review a pull request.**

Success is not measured by how quickly Reviewrr produces an automated verdict. It is measured by
whether a reviewer can make a more informed, more deliberate engineering decision with less wasted
navigation and better context.
