/**
 * Mirror of MutualA: builds a MutualA from inside its own pseudo-constructor.
 */
component {

	variables.otherKey = request.mutualRunId & "_a";
	if ( !structKeyExists( application, variables.otherKey ) ) {
		application[ variables.otherKey ] = "pending";
		sleep( 100 );
		application[ variables.otherKey ] = createObject( "component", "MutualA" );
	}

}
