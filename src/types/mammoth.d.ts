declare module "mammoth" {
  export type ConvertResult = {
    value: string;
    messages: Array<{ type: string; message: string; error?: unknown }>;
  };

  export type ConvertOptions = {
    buffer?: Buffer;
    path?: string;
  };

  export function convertToMarkdown(options: ConvertOptions): Promise<ConvertResult>;
  export function convertToHtml(options: ConvertOptions): Promise<ConvertResult>;
}
