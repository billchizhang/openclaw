import { createLazyRuntimeMethodBinder, createLazyRuntimeModule } from "../shared/lazy-runtime.js";

const loadOfficeConvert = createLazyRuntimeModule(() => import("./office-convert.js"));
const bindOfficeConvert = createLazyRuntimeMethodBinder(loadOfficeConvert);

export const tryConvertOfficeFile = bindOfficeConvert((m) => m.tryConvertOfficeFile);
