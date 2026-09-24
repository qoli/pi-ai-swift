#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
const [root, casesPath, outputPath] = process.argv.slice(2);
const fixture = JSON.parse(await readFile(casesPath, 'utf8'));
const revision = execFileSync('git', ['-C', root, 'rev-parse', 'HEAD'], {encoding:'utf8'}).trim();
if (revision !== fixture.upstreamRevision) throw new Error('revision mismatch');
const {providerHeadersToRecord} = await import(pathToFileURL(path.join(root,'packages/ai/src/utils/headers.ts')));
const cases = fixture.cases.map(item => ({...item, result:providerHeadersToRecord(...item.sources) ?? null}));
const rendered = JSON.stringify({upstreamRevision:revision,cases},null,2)+'\n';
if (outputPath) await writeFile(outputPath, rendered);
else process.stdout.write(rendered);
