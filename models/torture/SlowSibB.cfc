/**
 * Torture probe model (P1 siblings pair; P6 uses SlowSibA as the duplicate() source).
 * The sleep is in the LEAF pseudo-constructor only, so any serialization between SlowSibA
 * and SlowSibB can only come from the shared SlowSibBase lock being held by the leaf.
 */
component extends="models.torture.SlowSibBase" {

	variables.sibling = "B";
	variables.payload = { "name" : "SlowSibB", "items" : [ 1, 2, 3 ] };
	sleep( structKeyExists( request, "tortureSleepMs" ) ? request.tortureSleepMs : 200 );

}
