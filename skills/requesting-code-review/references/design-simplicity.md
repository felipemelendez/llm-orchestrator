## Design simplicity

Every review also answers: "Is this the simplest correct version?" Each of
the following is a reportable finding, not a style note, and the finding
names the simpler alternative:

- unnecessary abstraction or indirection
- extra state, flags or configuration the problem doesn't need
- duplicated mechanisms (a second way of doing something the codebase already does)
- a new helper or module where an existing one fits
- more code or more moving parts than the problem needs
- an architecture choice that adds coupling or lifecycle complexity without a stated reason

Severity follows harm: a design problem that will cause bugs, a maintenance
trap or a wrong architecture direction can be serious; a purely cosmetic one
is mild. A finding is valid only if the reviewer can show the simpler version
stays correct. "Simpler but subtly wrong" is not a valid finding.
