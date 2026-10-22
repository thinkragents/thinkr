#!/usr/bin/env node
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { createThinkrServer } from './server.js';

const server = createThinkrServer();
await server.connect(new StdioServerTransport());
