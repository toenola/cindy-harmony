import { url } from '@kit.ArkTS';
export interface ProjectRepository { url: string; name: string; }
// Port of fixed upstream 91179cedad repository normalization; all Git I/O remains on the host.
function hasRepositoryHostnamePrefix(text: string): boolean {
  const slash = text.indexOf("/");
  const host = slash >= 0 ? text.slice(0, slash) : "";
  return host.slice(1, -1).includes(".") && /^[\w.-]+$/.test(host);
}

/** Identify pasted addresses without treating an ordinary name as owner/repo shorthand. */
export function isExplicitProjectRepositoryAddress(input: string): boolean {
  const text = input.trim();
  if (text.length > 4096) return false;
  return (
    /^(?:https?:\/\/|ssh:\/\/|[\w.-]+@[\w.-]+:)/i.test(text) ||
    hasRepositoryHostnamePrefix(text)
  );
}

/** A repository address, never a local path or a Git remote-helper command. */
export function parseProjectRepository(
  input: string,
): ProjectRepository | null {
  let text = input.trim();
  if (!text || text.length > 4096 || /[\s\u0000-\u001f]/.test(text))
    return null;
  if (/^[\w.-]+\/[\w.-]+$/.test(text)) text = `https://github.com/${text}`;
  // Split once: adjacent wildcard-like hostname groups around a dot otherwise
  // backtrack quadratically on malformed addresses such as repeated "-.".
  if (hasRepositoryHostnamePrefix(text)) text = `https://${text}`;
  const scp = /^([\w.-]+)@([\w.-]+):([^/].*)$/.exec(text);
  if (scp) text = `ssh://${scp[1]}@${scp[2]}/${scp[3]}`;
  try {
    if (/(?:^|\/)\.\.?(?:\/|$)/.test(decodeURIComponent(text))) return null;
    const address = new url.URL(text);
    if (
      !["https:", "http:", "ssh:"].includes(address.protocol) ||
      !address.hostname ||
      address.password ||
      (address.protocol !== "ssh:" && address.username) ||
      (address.protocol === "ssh:" &&
        address.username &&
        !/^[\w.-]+$/.test(address.username))
    )
      return null;
    const segments = decodeURIComponent(address.pathname)
      .split("/")
      .filter(Boolean);
    if (address.hostname.toLowerCase() === "github.com") segments.splice(2);
    else {
      const marker = segments.indexOf("-");
      if (marker >= 0) segments.splice(marker);
    }
    if (
      segments.length < (address.hostname.toLowerCase() === "github.com" ? 2 : 1) ||
      segments.some(
        (part) =>
          part === "." || part === ".." || /[\\\u0000-\u001f]/.test(part),
      )
    )
      return null;
    const name: string = segments[segments.length - 1].replace(/\.git$/i, "");
    if (!name || name === "." || name === "..") return null;
    segments[segments.length - 1] = name + ".git";
    address.pathname = "/" + segments.map(encodeURIComponent).join("/");
    address.search = "";
    address.hash = "";
    return { url: address.toString(), name };
  } catch {
    return null;
  }
}

export function projectCreationFolderName(input: string): string {
  const name = input
    .replace(/[<>:"/\\|?*\u0000-\u001f]/g, "-")
    .trim()
    .slice(0, 80)
    .replace(/[. ]+$/, "");
  return !name ||
    name === "." ||
    name === ".." ||
    /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)/i.test(name)
    ? "Project"
    : name;
}
