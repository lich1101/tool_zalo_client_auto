// Module registry. Add new platform integrations here.
// Each entry must follow the Campaio Bridge module interface
// documented in ../module-api.md.

import zaloPersonal from "./zalo_personal/module.js";

export const MODULES = [zaloPersonal];

export function findModuleForUrl(url) {
  return MODULES.find((module) => {
    try {
      return module.match(url);
    } catch {
      return false;
    }
  }) || null;
}

export function findModuleById(id) {
  return MODULES.find((module) => module.id === id) || null;
}
