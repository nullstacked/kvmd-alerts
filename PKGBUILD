# Maintainer: nullstacked
pkgname=kvmd-alerts
pkgver=1.3.4
pkgrel=1
pkgdesc="Red banner on the PiKVM web UI when the target machine plays an isolated notification sound (Teams/Chat ping, incoming-call ring) - events from an audio-hub detector via nginx /alerts/"
arch=('any')
url="https://github.com/nullstacked/kvmd-alerts"
license=('GPL3')
depends=('kvmd')
install=kvmd-alerts.install

package() {
    install -Dm755 "$srcdir/../files/apply-patches.sh" "$pkgdir/usr/share/kvmd-alerts/apply-patches.sh"
    install -Dm644 "$srcdir/../files/alerts.css" "$pkgdir/usr/share/kvmd-alerts/alerts.css"
    install -Dm644 "$srcdir/../kvmd-alerts.hook" "$pkgdir/etc/pacman.d/hooks/kvmd-alerts.hook"
}
