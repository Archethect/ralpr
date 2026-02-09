/**
 * Shared child_process spawn helper.
 * Wraps spawn into a promise returning stdout + exitCode.
 */

import { spawn } from 'node:child_process';

export interface ExecResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

export function exec(cmd: string, args: string[], cwd?: string): Promise<ExecResult> {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, {
      cwd,
      stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...process.env },
    });

    const stdoutChunks: Buffer[] = [];
    const stderrChunks: Buffer[] = [];

    child.stdout.on('data', (chunk: Buffer) => stdoutChunks.push(chunk));
    child.stderr.on('data', (chunk: Buffer) => stderrChunks.push(chunk));

    child.on('close', (code) => {
      resolve({
        stdout: Buffer.concat(stdoutChunks).toString('utf-8').trim(),
        stderr: Buffer.concat(stderrChunks).toString('utf-8').trim(),
        exitCode: code ?? 1,
      });
    });

    child.on('error', () => {
      resolve({
        stdout: Buffer.concat(stdoutChunks).toString('utf-8').trim(),
        stderr: Buffer.concat(stderrChunks).toString('utf-8').trim(),
        exitCode: 1,
      });
    });
  });
}
