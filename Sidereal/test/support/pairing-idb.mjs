// Transactional, shared-origin pairing storage for synthetic browser handlers.
export const pairingDatabase = value => ({ value: structuredClone(value), tail: Promise.resolve() });
export function pairingIndexedDB(database, faults = {}) {
  return { open() {
    const request = {};
    queueMicrotask(() => {
      request.result = { close() {}, transaction(_store, mode) {
        const previous = database.tail;
        let release, finished = false, local;
        const operations = [];
        database.tail = new Promise(resolve => { release = resolve; });
        const transaction = {
          abort() {
            if (finished) return;
            finished = true; transaction.onabort?.(); release();
          },
          objectStore() { return {
            get: () => operation(() => structuredClone(local)),
            put: value => operation(() => {
              if (faults.storage) throw new Error('Storage unavailable');
              local = structuredClone(value); return 'mac';
            }),
            delete: () => operation(() => { local = undefined; }),
          }; },
        };
        function operation(work) {
          const item = {};
          operations.push(() => {
            try { item.result = work(); item.onsuccess?.(); }
            catch (error) { transaction.error = error; transaction.abort(); }
          });
          return item;
        }
        previous.then(() => {
          local = structuredClone(database.value);
          while (operations.length && !finished) operations.shift()();
          if (finished) return;
          const complete = () => {
            if (finished) return;
            finished = true;
            if (mode === 'readwrite') database.value = local;
            transaction.oncomplete?.(); release();
          };
          if (faults.holdCompletion && mode === 'readwrite') faults.pending.push({
            oncomplete: complete,
            onabort() { transaction.error = this.error; transaction.abort(); },
          });
          else complete();
        });
        return transaction;
      } };
      request.onsuccess();
    });
    return request;
  } };
}
