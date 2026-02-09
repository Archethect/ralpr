/**
 * PR comment routing.
 * Polls for unresolved review comments, routes to containers.
 */

import { exec } from './exec.js';

interface PrComment {
  id: string;
  body: string;
  author: string;
  isResolved: boolean;
  path: string;
  line: number | null;
}

const UNRESOLVED_QUERY = `
query($owner: String!, $repo: String!, $prNumber: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $prNumber) {
      reviewThreads(first: 100) {
        nodes {
          isResolved
          comments(first: 1) {
            nodes {
              id
              body
              author { login }
              path
              line
            }
          }
        }
      }
    }
  }
}`;

export async function pollPrComments(
  prNumber: number,
  seenIds: Set<string>,
): Promise<{ comments: PrComment[]; newSeenIds: Set<string> }> {
  const repoResult = await exec('gh', [
    'repo', 'view', '--json', 'owner,name',
  ]);

  if (repoResult.exitCode !== 0) return { comments: [], newSeenIds: seenIds };

  const repo = JSON.parse(repoResult.stdout) as { owner: { login: string }; name: string };

  const result = await exec('gh', [
    'api', 'graphql',
    '-f', `query=${UNRESOLVED_QUERY}`,
    '-F', `owner=${repo.owner.login}`,
    '-F', `repo=${repo.name}`,
    '-F', `prNumber=${prNumber}`,
  ]);

  if (result.exitCode !== 0) return { comments: [], newSeenIds: seenIds };

  const data = JSON.parse(result.stdout) as {
    data: {
      repository: {
        pullRequest: {
          reviewThreads: {
            nodes: Array<{
              isResolved: boolean;
              comments: {
                nodes: Array<{
                  id: string;
                  body: string;
                  author: { login: string };
                  path: string;
                  line: number | null;
                }>;
              };
            }>;
          };
        };
      };
    };
  };

  const threads = data.data.repository.pullRequest.reviewThreads.nodes;
  const newSeenIds = new Set(seenIds);
  const comments: PrComment[] = [];

  for (const thread of threads) {
    if (thread.isResolved) continue;
    const comment = thread.comments.nodes[0];
    if (!comment || seenIds.has(comment.id)) continue;

    newSeenIds.add(comment.id);
    comments.push({
      id: comment.id,
      body: comment.body,
      author: comment.author.login,
      isResolved: false,
      path: comment.path,
      line: comment.line,
    });
  }

  return { comments, newSeenIds };
}

export async function routeToContainer(
  containerName: string,
  comment: PrComment,
): Promise<boolean> {
  const message = JSON.stringify({
    type: 'pr-comment',
    id: comment.id,
    author: comment.author,
    path: comment.path,
    line: comment.line,
    body: comment.body,
  });

  const result = await exec('docker', [
    'exec', '-i', containerName,
    'sh', '-c', `echo '${message.replace(/'/g, "'\\''")}' >> /workspace/.ralpr/pr-comments.jsonl`,
  ]);

  return result.exitCode === 0;
}

export async function getPrNumberForBranch(branch: string): Promise<number | null> {
  const result = await exec('gh', [
    'pr', 'list',
    '--head', branch,
    '--json', 'number',
    '--limit', '1',
  ]);

  if (result.exitCode !== 0 || !result.stdout) return null;

  const prs = JSON.parse(result.stdout) as Array<{ number: number }>;
  return prs.length > 0 ? prs[0].number : null;
}
