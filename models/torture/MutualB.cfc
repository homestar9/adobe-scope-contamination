/**
 * Torture probe model (P2 mutual lazy init). Mirror of MutualA: lazily builds MutualA into
 * the application scope from inside its own pseudo-constructor. See MutualA for why the
 * pair deadlocks on a per-class construction lock.
 */
component {

	variables.otherKey = "torture_" & request.tortureRunId & "_a";
	if ( !structKeyExists( application, variables.otherKey ) ) {
		application[ variables.otherKey ] = "pending";
		sleep( structKeyExists( request, "tortureSleepMs" ) ? request.tortureSleepMs : 100 );
		application[ variables.otherKey ] = createObject( "component", "models.torture.MutualA" );
	}

}
