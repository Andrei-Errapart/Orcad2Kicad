import pytest


def test_is_power_net_gnd(dsn2kicad):
    assert dsn2kicad.is_power_net("GND") is True


def test_is_power_net_vdd(dsn2kicad):
    assert dsn2kicad.is_power_net("VDD_1V8") is True


def test_is_power_net_vcc(dsn2kicad):
    assert dsn2kicad.is_power_net("VCC") is True


def test_is_power_net_voltage_suffix(dsn2kicad):
    assert dsn2kicad.is_power_net("3.3V") is True


def test_is_power_net_signal(dsn2kicad):
    assert dsn2kicad.is_power_net("SPI_CLK") is False


def test_is_power_net_short(dsn2kicad):
    assert dsn2kicad.is_power_net("AB") is False


def test_is_power_net_vbus(dsn2kicad):
    assert dsn2kicad.is_power_net("VBUS") is True


def test_is_power_net_contains_vdd(dsn2kicad):
    assert dsn2kicad.is_power_net("CORE_VDD") is True


def test_is_gnd_power_name_gnd(dsn2kicad):
    assert dsn2kicad._is_gnd_power_name("GND") is True


def test_is_gnd_power_name_agnd(dsn2kicad):
    assert dsn2kicad._is_gnd_power_name("AGND") is True


def test_is_gnd_power_name_vcc(dsn2kicad):
    assert dsn2kicad._is_gnd_power_name("VCC") is False


def test_is_gnd_power_name_vss(dsn2kicad):
    assert dsn2kicad._is_gnd_power_name("VSS") is True


def test_pin_sort_key_numeric(dsn2kicad):
    assert dsn2kicad._pin_sort_key("42") == (0, 42, '')


def test_pin_sort_key_alpha(dsn2kicad):
    assert dsn2kicad._pin_sort_key("A1") == (1, 0, 'A1')


def test_pin_sort_key_zero(dsn2kicad):
    assert dsn2kicad._pin_sort_key("0") == (0, 0, '')


class TestInverseRotate:
    def test_identity(self, dsn2kicad):
        assert dsn2kicad._inverse_rotate(10, 5, 0x00) == (10, 5)

    def test_90(self, dsn2kicad):
        assert dsn2kicad._inverse_rotate(10, 5, 0x01) == (-5, 10)

    def test_180(self, dsn2kicad):
        assert dsn2kicad._inverse_rotate(10, 5, 0x02) == (-10, -5)

    def test_270(self, dsn2kicad):
        assert dsn2kicad._inverse_rotate(10, 5, 0x03) == (5, -10)

    def test_mirrored_90(self, dsn2kicad):
        assert dsn2kicad._inverse_rotate(10, 5, 0x05) == (-5, 10)


class TestForwardRotate:
    def test_identity(self, dsn2kicad):
        assert dsn2kicad._forward_rotate(10, 5, 0x00) == (10, 5)

    def test_90(self, dsn2kicad):
        assert dsn2kicad._forward_rotate(10, 5, 0x01) == (5, -10)

    def test_180(self, dsn2kicad):
        assert dsn2kicad._forward_rotate(10, 5, 0x02) == (-10, -5)

    def test_270(self, dsn2kicad):
        assert dsn2kicad._forward_rotate(10, 5, 0x03) == (-5, 10)

    def test_roundtrip(self, dsn2kicad):
        for orient in (0x00, 0x01, 0x02, 0x03, 0x05, 0x06, 0x07):
            dx, dy = 7, 3
            fwd = dsn2kicad._forward_rotate(dx, dy, orient)
            back = dsn2kicad._inverse_rotate(*fwd, orient)
            assert back == (dx, dy), f"roundtrip failed for orient 0x{orient:02x}"


class TestDirectionFromVector:
    def test_right(self, dsn2kicad):
        assert dsn2kicad._direction_from_vector(0, 0, 10, 0) == 0

    def test_left(self, dsn2kicad):
        assert dsn2kicad._direction_from_vector(0, 0, -10, 0) == 180

    def test_down(self, dsn2kicad):
        assert dsn2kicad._direction_from_vector(0, 0, 0, 10) == 90

    def test_up(self, dsn2kicad):
        assert dsn2kicad._direction_from_vector(0, 0, 0, -10) == 270


class TestOrientToAngle:
    def test_resistor_default(self, dsn2kicad):
        assert dsn2kicad.orient_to_angle(0x00, 'R') == 90

    def test_resistor_90(self, dsn2kicad):
        assert dsn2kicad.orient_to_angle(0x01, 'R') == 0

    def test_generic_default(self, dsn2kicad):
        assert dsn2kicad.orient_to_angle(0x00, 'IC1') == 0

    def test_generic_90(self, dsn2kicad):
        assert dsn2kicad.orient_to_angle(0x01, 'IC1') == 90

    def test_generic_180(self, dsn2kicad):
        assert dsn2kicad.orient_to_angle(0x02, 'IC1') == 180

    def test_generic_270(self, dsn2kicad):
        assert dsn2kicad.orient_to_angle(0x03, 'IC1') == 270


class TestComputeWireEndpoints:
    def test_simple_chain(self, dsn2kicad):
        wires = [
            {'x1': 0, 'y1': 0, 'x2': 10, 'y2': 0, 'net': 'N'},
            {'x1': 10, 'y1': 0, 'x2': 20, 'y2': 0, 'net': 'N'},
        ]
        endpoints = dsn2kicad.compute_wire_endpoints(wires)
        assert endpoints == {(0, 0), (20, 0)}

    def test_single_wire(self, dsn2kicad):
        wires = [{'x1': 5, 'y1': 5, 'x2': 15, 'y2': 15, 'net': 'N'}]
        endpoints = dsn2kicad.compute_wire_endpoints(wires)
        assert endpoints == {(5, 5), (15, 15)}


class TestComputeJunctions:
    def test_t_junction(self, dsn2kicad):
        wires = [
            {'x1': 0, 'y1': 0, 'x2': 10, 'y2': 0, 'net': 'N'},
            {'x1': 10, 'y1': 0, 'x2': 20, 'y2': 0, 'net': 'N'},
            {'x1': 10, 'y1': 0, 'x2': 10, 'y2': 10, 'net': 'N'},
        ]
        junctions = dsn2kicad.compute_junctions(wires)
        assert (10, 0) in junctions

    def test_no_junction(self, dsn2kicad):
        wires = [
            {'x1': 0, 'y1': 0, 'x2': 10, 'y2': 0, 'net': 'N'},
            {'x1': 10, 'y1': 0, 'x2': 20, 'y2': 0, 'net': 'N'},
        ]
        junctions = dsn2kicad.compute_junctions(wires)
        assert len(junctions) == 0
