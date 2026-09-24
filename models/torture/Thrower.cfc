/**
 * Torture probe model (P4 lock leak; also constructed by Catcher). Throws from its
 * pseudo-constructor every Nth construction, N = request.tortureThrowEvery, counted by a
 * request-scoped AtomicInteger shared by all of the probe's threads. A construction lock
 * that is not released on this exceptional path would hang every later construction.
 */
component {

	if (
		structKeyExists( request, "tortureThrowEvery" ) && request.tortureThrowEvery > 0
		&& structKeyExists( request, "tortureThrowCounter" )
		&& request.tortureThrowCounter.incrementAndGet() mod request.tortureThrowEvery == 0
	) {
		throw( type = "Torture.Thrower", message = "Thrower: deliberate pseudo-constructor failure" );
	}
	variables.built = true;

}
