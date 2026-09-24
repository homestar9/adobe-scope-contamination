/**
 * Torture probe model (P1 same/unrelated/alias/mapping/outer pairs; P5 unrelated target).
 * No extends, so on the per-class jar its construction holds exactly one lock: its own.
 * The sleep sits in the pseudo-constructor, which runs INSIDE resolveName and therefore
 * inside whatever construction lock the engine takes.
 */
component {

	variables.leaf = "A";
	sleep( structKeyExists( request, "tortureSleepMs" ) ? request.tortureSleepMs : 200 );

}
