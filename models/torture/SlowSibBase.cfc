/**
 * Torture probe model (P1 siblings pair, P6). Shared ancestor of SlowSibA and SlowSibB.
 * Deliberately does no work: the point is only that resolving it nests a second
 * resolveName, so on the per-class jar each sibling holds this base's lock for the whole
 * of its own (slow) pseudo-constructor.
 */
component {

	variables.base = true;

}
