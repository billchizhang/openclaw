import { execFile } from "node:child_process";
import fs from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import mammoth from "mammoth";
import * as XLSX from "xlsx";
import { logVerbose, shouldLogVerbose } from "../globals.js";
import { extractPdfContent } from "../media/pdf-extract.js";

const execFileAsync = promisify(execFile);

const LIBREOFFICE_TIMEOUT_MS = 60_000;

// Cached availability result so we only probe soffice once per process
let libreOfficeAvailable: boolean | undefined;

async function isLibreOfficeAvailable(): Promise<boolean> {
  if (libreOfficeAvailable !== undefined) {
    return libreOfficeAvailable;
  }
  try {
    await execFileAsync("soffice", ["--version"], { timeout: 5000 });
    libreOfficeAvailable = true;
  } catch {
    libreOfficeAvailable = false;
  }
  return libreOfficeAvailable;
}

async function convertToPdfViaLibreOffice(buffer: Buffer, ext: string): Promise<Buffer | null> {
  if (!(await isLibreOfficeAvailable())) {
    return null;
  }
  let tmpDir: string | undefined;
  try {
    tmpDir = await fs.mkdtemp(path.join(tmpdir(), "openclaw-office-"));
    const inputPath = path.join(tmpDir, `input${ext}`);
    await fs.writeFile(inputPath, buffer);
    await execFileAsync(
      "soffice",
      ["--headless", "--convert-to", "pdf", "--outdir", tmpDir, inputPath],
      { timeout: LIBREOFFICE_TIMEOUT_MS },
    );
    return await fs.readFile(path.join(tmpDir, "input.pdf"));
  } catch (err) {
    if (shouldLogVerbose()) {
      logVerbose(`office-convert: LibreOffice PDF conversion failed (${ext}): ${String(err)}`);
    }
    return null;
  } finally {
    if (tmpDir) {
      await fs.rm(tmpDir, { recursive: true, force: true }).catch(() => {});
    }
  }
}

async function extractTextFromPdfBuffer(pdfBuffer: Buffer): Promise<string | null> {
  try {
    const result = await extractPdfContent({
      buffer: pdfBuffer,
      maxPages: 100,
      maxPixels: 4_000_000,
      minTextChars: 0,
    });
    return result.text.trim() || null;
  } catch (err) {
    if (shouldLogVerbose()) {
      logVerbose(`office-convert: PDF text extraction failed: ${String(err)}`);
    }
    return null;
  }
}

export type OfficeConvertResult = {
  text: string;
  /** MIME type of the converted content (text/csv, text/markdown, or application/pdf) */
  mime: string;
};

async function convertXlsx(buffer: Buffer): Promise<OfficeConvertResult | null> {
  try {
    const wb = XLSX.read(buffer, { type: "buffer" });
    if (wb.SheetNames.length === 0) {
      return null;
    }
    const parts: string[] = [];
    for (const sheetName of wb.SheetNames) {
      const ws = wb.Sheets[sheetName];
      if (!ws) {
        continue;
      }
      const csv = XLSX.utils.sheet_to_csv(ws).trim();
      if (csv) {
        parts.push(`## Sheet: ${sheetName}\n${csv}`);
      }
    }
    return parts.length > 0 ? { text: parts.join("\n\n"), mime: "text/csv" } : null;
  } catch (err) {
    if (shouldLogVerbose()) {
      logVerbose(`office-convert: xlsx conversion failed: ${String(err)}`);
    }
    return null;
  }
}

async function convertDocx(buffer: Buffer): Promise<OfficeConvertResult | null> {
  // Prefer LibreOffice → PDF (preserves layout, tables, images)
  const pdfBuffer = await convertToPdfViaLibreOffice(buffer, ".docx");
  if (pdfBuffer) {
    const text = await extractTextFromPdfBuffer(pdfBuffer);
    if (text) {
      return { text, mime: "application/pdf" };
    }
  }
  // Fallback: mammoth → markdown (pure Node.js, text-only)
  try {
    const result = await mammoth.convertToMarkdown({ buffer });
    const text = result.value.trim();
    return text ? { text, mime: "text/markdown" } : null;
  } catch (err) {
    if (shouldLogVerbose()) {
      logVerbose(`office-convert: docx mammoth conversion failed: ${String(err)}`);
    }
    return null;
  }
}

async function convertPptx(buffer: Buffer): Promise<OfficeConvertResult | null> {
  // Only LibreOffice can handle pptx; no pure-Node.js fallback
  const pdfBuffer = await convertToPdfViaLibreOffice(buffer, ".pptx");
  if (!pdfBuffer) {
    return null;
  }
  const text = await extractTextFromPdfBuffer(pdfBuffer);
  return text ? { text, mime: "application/pdf" } : null;
}

/**
 * Attempts to convert an Office file (.xlsx, .docx, .pptx) to extractable text.
 * Returns null if the extension is unrecognized or all conversion paths fail.
 */
export async function tryConvertOfficeFile(
  ext: string,
  buffer: Buffer,
): Promise<OfficeConvertResult | null> {
  switch (ext) {
    case ".xlsx":
      return convertXlsx(buffer);
    case ".docx":
      return convertDocx(buffer);
    case ".pptx":
      return convertPptx(buffer);
    default:
      return null;
  }
}
