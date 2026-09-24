/**
 * Builds a MutualB from inside its own pseudo-constructor, the first time it is constructed
 * for a given run. MutualB mirrors this. Two threads that start at MutualA and MutualB at the
 * same moment each hold their own class's construction lock while waiting for the other's.
 */
component {

	variables.otherKey = request.mutualRunId & "_b";
	if ( !structKeyExists( application, variables.otherKey ) ) {
		application[ variables.otherKey ] = "pending";
		sleep( 100 ); // widens the window; in real code this is the pseudo-constructor's own work
		application[ variables.otherKey ] = createObject( "component", "MutualB" );
	}

}
