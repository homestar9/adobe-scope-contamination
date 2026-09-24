/**
 * Torture probe model (P5 cfthread inside construction).
 *
 * Its pseudo-constructor spawns a cfthread that constructs request.tortureP5.target, then
 * joins that thread with a timeout. The spawned thread is a different Java thread, so it
 * does not share the parent's (thread-local) held-lock set: if the target needs any lock
 * the parent is holding (itself, or the shared SpawnerBase), the child waits until the
 * parent's join times out and the parent's construction returns.
 *
 * ACF limitation worked around: the `thread` statement is not placed directly in the
 * component body. A cfthread body is compiled as a function of the enclosing template, and
 * declaring one at pseudo-constructor level is not reliably supported, so the pseudo-
 * constructor calls spawnAndJoin() instead. Methods are bound before the pseudo-constructor
 * runs, and the call still happens inside resolveName, so the lock picture is unchanged.
 *
 * Recursion guard: request.tortureDepth is set to 1 before the spawn, so a ThreadSpawner
 * constructed by the child (the "same" target) does not spawn again. The request scope is
 * shared by the request and its cfthreads.
 */
component extends="models.torture.SpawnerBase" {

	if (
		structKeyExists( request, "tortureP5" )
		&& structKeyExists( request, "tortureDepth" ) && request.tortureDepth == 0
	) {
		spawnAndJoin();
	}

	private void function spawnAndJoin() {
		request.tortureDepth = 1;
		var p5    = request.tortureP5;
		var tName = "torture_p5_" & replace( createUUID(), "-", "", "all" );
		p5[ "childName" ] = tName;
		p5[ "spawnTick" ] = getTickCount();

		thread name="#tName#" action="run" target="#p5.target#" {
			try {
				createObject( "component", attributes.target );
				request.tortureP5[ "childOk" ] = true;
			} catch ( any e ) {
				request.tortureP5[ "childError" ] = e.message;
			}
			request.tortureP5[ "childDoneTick" ] = getTickCount();
		}

		var t0 = getTickCount();
		thread action="join" name="#tName#" timeout="#p5.joinMs#";
		p5[ "joinWaitMs" ] = getTickCount() - t0;
		// Judged by the child's own completion marker rather than cfthread status, which
		// is not reliably visible from inside a component's pseudo-constructor.
		p5[ "timedOut" ] = !structKeyExists( p5, "childDoneTick" );
	}

}
