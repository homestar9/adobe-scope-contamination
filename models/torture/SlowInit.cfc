/**
 * Torture probe model (P1 slowinit pair). The pseudo-constructor is empty and the sleep
 * lives in init(). init() is invoked by the `new` operator AFTER resolveName returns, so it
 * runs outside any construction lock: two concurrent `new SlowInit()` calls are expected to
 * overlap on every arm, which is exactly what shows init() is unprotected on the v3 jar.
 */
component {

	variables.initialized = false;

	function init() {
		sleep( structKeyExists( request, "tortureSleepMs" ) ? request.tortureSleepMs : 200 );
		variables.initialized = true;
		return this;
	}

}
