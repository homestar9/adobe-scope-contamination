/**
 * Torture probe model (P3 cflock interlock). Takes the named lock "torture-L" briefly in its
 * pseudo-constructor. LockTargetX is the class the lock holder constructs (same-class
 * variant); LockTargetZ is a different file that takes the same named lock (unrelated
 * variant), so it only interlocks on an engine whose construction lock is global.
 */
component {

	variables.target = "X";
	lock name="torture-L" type="exclusive" timeout=3 {
		sleep( structKeyExists( request, "tortureSleepMs" ) ? request.tortureSleepMs : 10 );
	}

}
