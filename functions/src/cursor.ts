/**
 * Orders the watch list to start just after [cursor] (the last document
 * the previous run attempted) and wrap around. A run that hits its time
 * budget then resumes where it stopped, instead of re-refreshing the same
 * head of the list and never reaching the tail.
 *
 * IDs are compared by code unit (not localeCompare) so the order doesn't
 * depend on the runtime's locale. A cursor that no longer exists still
 * resumes at the next ID after it.
 */
export function orderAfterCursor(ids: string[], cursor: unknown): string[] {
  const sorted = [...ids].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  if (typeof cursor !== "string") return sorted;
  const start = sorted.findIndex((id) => id > cursor);
  if (start <= 0) return sorted;
  return [...sorted.slice(start), ...sorted.slice(0, start)];
}
