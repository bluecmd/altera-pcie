all: cli

cli: FORCE
	GUI=0 vsim -c -do sim.do && grep -qP "^# SUCCESS: Simulation stopped due to successful completion!$$" transcript

gui: FORCE
	GUI=1 vsim -do sim.do > /dev/null &

clean: FORCE
	rm -rf work pcie transcript virtuals.do vsim.wlf modelsim.ini fontconfig wlf*

FORCE:
