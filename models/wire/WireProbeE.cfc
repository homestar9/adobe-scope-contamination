/**
 * Wire probe E: one of six UNRELATED transients (no extends, no shared base class) built
 * through WireBox on every /repro/wire request. It uses the same construction features a Quick
 * entity does: property injection (a singleton, the injector, a transient), a constructor
 * argument injected by WireBox plus one passed through initArguments, and more construction
 * inside onDIComplete. report() lets the handler check that every value in this instance's
 * variables scope belongs to the request that built it.
 */
component {

	property name="wirebox"  inject="wirebox";
	property name="registry" inject="models.wire.WireRegistry";
	property name="helper"   inject="models.wire.WireHelper";

	function init( required string token, any peer inject="models.wire.WireHelper" ) {
		variables.kind  = "E";
		variables.token = arguments.token;
		variables.peer  = arguments.peer;
		return this;
	}

	function onDIComplete() {
		variables.settings = structCopy( variables.registry.settingsFor( variables.kind ) );
		variables.worker   = variables.wirebox.getInstance( "models.wire.WireHelper" );
		variables.worker.setOwnerToken( variables.token );
		variables.helper.setOwnerToken( variables.token );
		variables.peer.setOwnerToken( variables.token );
	}

	struct function report() {
		return {
			"kind"         : variables.kind,
			"token"        : variables.token,
			"settingsKind" : variables.settings.kind,
			"workerOwner"  : variables.worker.getOwnerToken(),
			"helperOwner"  : variables.helper.getOwnerToken(),
			"peerOwner"    : variables.peer.getOwnerToken(),
			"metaName"     : getMetadata( this ).name
		};
	}

}
