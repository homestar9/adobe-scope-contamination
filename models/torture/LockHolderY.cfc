/**
 * Torture probe model (P3 cflock interlock, holder=cfc). Takes the named lock "torture-L"
 * INSIDE its pseudo-constructor (so inside its own construction lock on the v3 jar), sleeps,
 * then constructs LockTargetX while still holding "torture-L". If another thread is already
 * inside LockTargetX's construction waiting for "torture-L", the two wait on each other
 * until the 3 s cflock timeout breaks the cycle.
 */
component {

	lock name="torture-L" type="exclusive" timeout=3 {
		sleep( structKeyExists( request, "tortureSleepMs" ) ? request.tortureSleepMs : 50 );
		variables.target = createObject( "component", "models.torture.LockTargetX" );
	}

}
