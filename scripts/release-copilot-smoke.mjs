// Local SDK/runtime paths are explicit arguments; no package install or download.
import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
const [sdk, runtime, configFile, output] = process.argv.slice(2);
const {CopilotClient, RuntimeConnection} = await import(pathToFileURL(sdk));
const cfg = JSON.parse(fs.readFileSync(configFile, 'utf8'));
const result = {client:'Copilot bundled SDK/runtime', runtime, profile:cfg.profile};
const client = new CopilotClient({
  connection:RuntimeConnection.forStdio({path:runtime}),
  baseDirectory:cfg.home, workingDirectory:cfg.root, useLoggedInUser:false,
  env:{...process.env, COPILOT_HOME:cfg.home, COPILOT_OFFLINE:'true', COPILOT_AUTO_UPDATE:'false',
    COPILOT_PROVIDER_BASE_URL:'http://127.0.0.1:1', COPILOT_OTEL_ENABLED:'false'},
});
let session;
try {
  await client.start();
  session = await client.createSession({
    workingDirectory:cfg.root, mcpServers:{release_smoke:cfg.server},
    onPermissionRequest:async () => ({kind:'approved'}),
    provider:{type:'openai',baseUrl:'http://127.0.0.1:1'},model:'local-smoke-no-inference'});
  await session.rpc.mcp.reload();
  result.inventory = await session.rpc.mcp.list();
  result.tools = await session.rpc.mcp.listTools({serverName:'release_smoke'});
  await session.rpc.tools.initializeAndValidate();
  result.metadata = await session.rpc.tools.getCurrentMetadata();
  result.calls = [];
  for (const [name,args] of [['codedb_status',{}],['codedb_symbol',{name:'releaseSmoke'}],['codedb_read',{path:'smoke.ts',line_start:1,line_end:2}]]) {
    const offered = result.metadata.tools?.find(t => t.name.includes('release_smoke') && t.name.endsWith(name));
    result.calls.push(await session.rpc.tools.execute({name:offered?.name ?? 'release_smoke-'+name,arguments:args}));
  }
  result.passed = JSON.stringify(result.calls.at(-1)).includes('releaseSmoke');
} catch (error) {result.error = String(error);}
finally {
  if (session) await session.disconnect().catch(()=>{});
  await client.stop().catch(()=>{});
  fs.writeFileSync(output,JSON.stringify(result,null,2));
}
console.log(cfg.profile, result.passed ?? false, result.error ?? '');
