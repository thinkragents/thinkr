import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { tools } from './tools.js';

export function createThinkrServer() {
  const server = new McpServer({ name: 'thinkr', version: '0.1.0' });

  for (const tool of tools) {
    server.registerTool(
      tool.name,
      {
        title: tool.title,
        description: tool.description,
        inputSchema: tool.schema,
        annotations: { readOnlyHint: Boolean(tool.readOnly), openWorldHint: true },
      },
      async (args) => {
        try {
          const result = await tool.run(args);
          return { content: [{ type: 'text', text: JSON.stringify(result, null, 2) }] };
        } catch (err) {
          // An agent deciding whether to pay someone must never read a failure as a
          // clean answer, so errors come back marked, with the reason intact.
          return {
            isError: true,
            content: [{ type: 'text', text: JSON.stringify({ error: err.message, code: err.code ?? 'error' }, null, 2) }],
          };
        }
      }
    );
  }

  return server;
}
