/**
 * Torture probe model (P5). Shared ancestor of ThreadSpawner and SpawnerSibling. On the
 * per-class jar a ThreadSpawner construction holds this base's lock, so a child thread
 * constructing SpawnerSibling has to wait for it (the "sibling" target).
 */
component {

	variables.base = true;

}
