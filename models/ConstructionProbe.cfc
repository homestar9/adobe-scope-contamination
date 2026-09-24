/**
 * Minimal transient used to isolate CFC construction from database, Quick,
 * and WireBox work during hotfix benchmarks.
 */
component {

	variables.value = 0;

	function init() {
		return this;
	}

	function setValue( required numeric value ) {
		variables.value = arguments.value;
		return this;
	}

	numeric function getValue() {
		return variables.value;
	}

}
