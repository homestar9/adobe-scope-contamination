/**
 * Torture probe model (P2 mutual lazy init). Lazily builds MutualB into the application
 * scope from inside its own pseudo-constructor; MutualB mirrors this for MutualA.
 *
 * Two threads, one starting at each side, both see the other's key missing, mark it
 * "pending", sleep, and then each constructs the other class while still holding its own
 * construction lock. Stock (no lock) and v1 (one reentrant monitor) complete; the per-class
 * jar parks both threads on each other's ReentrantLock forever (uninterruptible lock()).
 * Keys are namespaced by request.tortureRunId so the two sides of one run share them.
 */
component {

	variables.otherKey = "torture_" & request.tortureRunId & "_b";
	if ( !structKeyExists( application, variables.otherKey ) ) {
		application[ variables.otherKey ] = "pending";
		sleep( structKeyExists( request, "tortureSleepMs" ) ? request.tortureSleepMs : 100 );
		application[ variables.otherKey ] = createObject( "component", "models.torture.MutualB" );
	}

}
