/**
 * Wire probe helper: a small transient that records which request built it.
 * Built through WireBox as a property-injected, constructor-injected and nested dependency of
 * every WireProbe class (see handlers/Repro.cfc wire()).
 */
component {

	function init() {
		variables.stamp = createUUID();
		variables.ownerToken = "";
		return this;
	}

	function getStamp() {
		return variables.stamp;
	}

	function setOwnerToken( required string token ) {
		variables.ownerToken = arguments.token;
		return this;
	}

	function getOwnerToken() {
		return variables.ownerToken;
	}

}
