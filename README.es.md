<p align="center">
  <img src="assets/icon.svg" alt="Icono de VPN NetGuard" width="140">
</p>

<h1 align="center">VPN NetGuard</h1>

<p align="center">
  Kill switch, reconexión automática y anonimato de red para tu VPN en Linux.<br>
  Un único script: panel gráfico, menú de terminal o servicio systemd headless — tú eliges.
</p>

<p align="center">
  <img alt="Bash 4+" src="https://img.shields.io/badge/bash-%3E%3D4.0-4EAA25?logo=gnubash&logoColor=white">
  <img alt="Linux Mint 22.3 Cinnamon" src="https://img.shields.io/badge/Linux%20Mint-22.3%20Cinnamon-87CF3E?logo=linuxmint&logoColor=white">
  <img alt="Debian/Ubuntu Server headless" src="https://img.shields.io/badge/Debian%2FUbuntu-Server%20headless-A81D33?logo=debian&logoColor=white">
  <a href="LICENSE"><img alt="Licencia GPLv3" src="https://img.shields.io/badge/licencia-GPLv3-blue"></a>
  <img alt="Versión 1.0.0" src="https://img.shields.io/badge/version-1.0.0-informational">
</p>

<p align="center">
  <b>Español</b> · <a href="README.md">English</a>
</p>

---

## Índice

- [¿Qué es VPN NetGuard?](#qué-es-vpn-netguard)
- [Primeros pasos](#primeros-pasos)
- [El problema que resuelve](#el-problema-que-resuelve)
- [Qué hace exactamente](#qué-hace-exactamente)
- [Instalación](#instalación)
- [Comandos](#comandos)
- [Uso diario](#uso-diario)
- [Configuración](#configuración)
- [Compatibilidad](#compatibilidad)
- [Scriptya](#scriptya)
- [Sobre el idioma](#sobre-el-idioma)
- [Contribuir](#contribuir)
- [Seguridad](#seguridad)
- [Licencia](#licencia)

## ¿Qué es VPN NetGuard?

VPN NetGuard es una **herramienta de privacidad** para Linux. Si usas una VPN para que tu operador de Internet, la red wifi en la que estés o las páginas que visitas no puedan ver lo que haces ni tu ubicación real, VPN NetGuard se encarga de que esa protección no falle sin que te enteres.

<img width="699" height="576" alt="terminal-menu-vpnnetguard-es" src="https://github.com/user-attachments/assets/ebc6008b-4173-421c-821a-1be4298ede41" />
<img width="556" height="550" alt="menu-vpnnetguard-es" src="https://github.com/user-attachments/assets/03a0f421-a6bd-46b4-a6dd-30b32dde5208" />

En concreto, te protege de dos cosas:

- **De que tu VPN falle en silencio.** Si la conexión se cae, el ordenador se reinicia o el túnel deja de funcionar sin avisar, lo normal es que tu tráfico "real" (sin proteger) empiece a salir a Internet sin que lo notes, dejando al descubierto tu IP y tu actividad. VPN NetGuard corta todo el tráfico en cuanto detecta que la VPN no está funcionando y no deja pasar nada hasta que vuelve a estar activa — ni siquiera durante el propio arranque del equipo.
- **De que te identifiquen aunque la VPN funcione bien.** Al margen de tu tráfico, tu ordenador se presenta ante cualquier red wifi (la del bar, el aeropuerto o la oficina) con datos como su dirección MAC o su nombre de equipo. Eso permite que te reconozcan y te sigan la pista de una red a otra, incluso con la VPN activa. VPN NetGuard puede ocultar y cambiar esos datos automáticamente.

Y esto no depende de que el fallo sea de la propia VPN: si lo que falla es tu conexión a Internet —un wifi inestable que entra y sale, un router que se atasca—, VPN NetGuard responde igual de bien. En cuanto vuelve a haber señal, reconecta la VPN enseguida y por su cuenta, para que estés protegido y de vuelta online cuanto antes, sin que tengas que tocar nada.

En resumen: si tu VPN es la cerradura, VPN NetGuard es quien vigila que la puerta esté siempre bien cerrada — y de paso te ayuda a no dejar huellas por el camino.

Y no hace falta que sea tu ordenador de escritorio: funciona igual en un servidor sin pantalla al que solo entras por SSH —un VPS, un NAS, una Raspberry Pi...—. Es el mismo script en los dos casos: él mismo detecta dónde se está ejecutando y se adapta solo, sin que tengas que indicar nada.

## Primeros pasos

Si solo quieres probarlo, esto es todo lo que hace falta:

1. **Descarga el script:**

   ```bash
   git clone https://github.com/filonux/VPN-NetGuard.git
   cd VPN-NetGuard/script
   ```

2. **Instálalo.** En un escritorio (por ejemplo, Linux Mint):

   ```bash
   pkexec bash vpn-netguard.sh install
   ```

   En un servidor sin pantalla, por SSH:

   ```bash
   sudo bash vpn-netguard.sh install
   ```

   Aparece un asistente (gráfico o de texto, según el caso) que hace un par de preguntas sencillas de sí/no, y con eso ya está instalado.

3. **Úsalo en el día a día** sin volver a tocar la terminal: busca "VPN NetGuard" en el menú de Aplicaciones (o haz doble clic en el icono del Escritorio, si marcaste esa opción al instalar). Se abre una ventana con una lista de acciones agrupadas por categoría; las que usarás casi siempre están arriba del todo — "Ver estado actual", "Activar protección VPN" y "Desactivar protección VPN" — y si es la primera vez, "1-click y olvidar" lo deja todo configurado y conectado en un único paso. Haces doble clic en la opción que quieras y, en cuanto termina, la misma ventana vuelve a aparecer para la siguiente, sin comandos que memorizar.

   Si prefieres manejarlo desde una terminal (por ejemplo, por SSH en un servidor sin pantalla), existe el mismo tipo de menú pero en modo texto: ejecuta `vpn-netguard.sh` sin nada más y elige cada opción con el teclado, sin necesidad de recordar ningún comando tampoco.

¿Necesitas más detalle — banderas para instalación desatendida, cómo desinstalar, la lista completa de comandos...? Sigue leyendo: las secciones de abajo entran en todo lo demás, empezando por el porqué de cada decisión de diseño.

## El problema que resuelve

La mayoría de los "kill switch para VPN" que circulan por foros son dos o tres reglas de `iptables` aplicadas a mano, una vez. Funcionan mientras nada cambia — pero si la VPN se cae de madrugada, el portátil se reinicia o el túnel se queda "zombie" (la interfaz sigue arriba pero el servidor remoto ya no responde), esas reglas no se enteran de nada y tu tráfico real sale a Internet sin protección, sin que lo notes.

VPN NetGuard es un demonio que vigila la conexión sin parar, no una regla suelta. La diferencia se nota justo en los momentos donde un kill switch casero falla: el propio arranque del sistema (antes incluso de que exista red), un túnel zombie que un simple ping no detectaría, o el rato en que nadie está mirando. Por separado, añade un módulo de anonimato de red para que, aunque la VPN vaya perfecta, el router del bar, del aeropuerto o de la oficina no pueda reconocerte por tu MAC, tu IPv6 o el nombre de tu equipo — algo que ningún kill switch por sí solo cubre. El cómo de cada cosa está en el siguiente apartado.

## Qué hace exactamente

VPN NetGuard reúne en un solo fichero lo que antes eran siete (el vigilante, el panel, el instalador, la configuración, dos unidades de systemd y el lanzador de escritorio). Esto es lo que hace:

### Kill switch de verdad (fail-closed)

- Bloquea todo el tráfico saliente que no pase por el túnel VPN, con reglas de `iptables` e `ip6tables` que se aplican de forma atómica: nunca hay un instante en el que la cadena quede a medio construir o vacía.
- Un segundo servicio systemd, independiente del principal, cierra el tráfico *antes* de que la red esté siquiera configurada al arrancar — la ventana de fuga que casi ningún otro script cubre.
- Permite explícitamente lo mínimo necesario para funcionar: DNS (solo hacia los servidores que definas, no hacia cualquiera), el propio establecimiento del túnel, tráfico de tu LAN si lo activas, y ping hacia los objetivos que uses para comprobar que hay Internet real.
- Tres modos, según lo que necesites: `auto` (el bloqueo se activa solo cuando tú activas la VPN), `true` (bloqueo permanente mientras el servicio corre) o `false` (solo vigila y reconecta, sin bloquear nada).

### Vigilancia y reconexión automática

- Reacciona al instante a los eventos de NetworkManager (`nmcli monitor`) y, además, hace una comprobación de respaldo cada pocos segundos por si algo se escapa.
- Reintenta la conexión VPN con espera progresiva (*backoff*) para no machacar un servidor que lleva un rato caído.
- Con WireGuard no se fía de que la interfaz siga "arriba": mide la antigüedad del último *handshake* para detectar un túnel zombie que un simple ping no delataría.
- Se apoya en el *watchdog* de systemd: si algo se queda colgado (una llamada a `nmcli` o `iptables` que nunca vuelve), systemd reinicia el servicio solo, sin que tengas que intervenir.

### Anonimato de red (independiente de la VPN)

- MAC aleatoria por red: la misma MAC cada vez que vuelves a una red conocida, o una distinta en cada conexión, a tu elección — con la opción de que el fabricante que se muestra parezca real en vez de "obviamente aleatorio".
- Aleatoriza también la MAC usada al escanear redes Wi-Fi, antes incluso de conectarte a ninguna.
- Oculta el nombre de tu equipo frente al DHCP del router y corrige una fuga poco conocida (el identificador de cliente DHCP, el DUID y el IAID) que puede delatarte igualmente aunque la MAC ya cambie.
- Direcciones IPv6 privadas y temporales, o la opción de desactivar IPv6 por completo si prefieres minimizar la huella al máximo.
- Puede silenciar el anuncio de tu nombre de equipo por mDNS/Avahi y por NetBIOS, y forzar que Firefox, Chrome y Chromium dejen de resolver DNS por su cuenta (DNS-over-HTTPS) para que respeten tu configuración de DNS y el propio kill switch.

### Alertas, historial y monitorización

- Notificaciones de escritorio cuando el estado cambia de verdad, no en cada comprobación periódica.
- Un "gancho" de alertas (`ALERT_HOOK`) para servidores sin escritorio: engancha ahí un webhook, un correo o lo que necesites.
- Historial de eventos en CSV, pensado para importarlo en una hoja de cálculo o graficar disponibilidad en el tiempo.
- Métricas para Prometheus (formato *textfile collector* de node_exporter) y un subcomando `check` con código de salida, listo para cron, Nagios o Zabbix.

### Tres formas de manejarlo

- Panel gráfico (zenity) para el día a día en el escritorio.
- Menú interactivo en la terminal, que no necesita zenity ni tener el programa ya instalado — pensado para usar por SSH.
- Subcomandos directos para automatizar, depurar o integrar en tus propios scripts.

## Instalación

El instalador detecta solo si tienes sesión gráfica y elige el asistente adecuado — no hay que indicar nada. Usa los mismos comandos de [Primeros pasos](#primeros-pasos) (`pkexec bash vpn-netguard.sh install` en escritorio, `sudo bash vpn-netguard.sh install` por SSH); esto es lo que pregunta cada asistente:

- **Con sesión gráfica (zenity):** arranque automático, inicio inmediato del servicio, entrada en el menú de Aplicaciones —y, si dices que sí, icono de Escritorio también— y si aplicar el anonimato de red ahora.
- **Por SSH, en modo texto:** las mismas preguntas salvo la del icono de Escritorio, que no aplica sin sesión gráfica.

La pregunta sobre el anonimato de red aparece siempre; si el instalador detecta que estás conectado por SSH, muestra antes un aviso más contundente, porque cambiar la MAC podría cortar tu propia conexión si tu proveedor filtra por ella.

**Instalación desatendida (Ansible, cloud-init, Dockerfile...):** `install` también admite banderas —o las variables de entorno `VPN_NETGUARD_INSTALL_*`— que evitan las preguntas interactivas de sí/no:

```bash
sudo bash vpn-netguard.sh install --yes
sudo bash vpn-netguard.sh install --autostart --start-now --no-privacy
```

`--yes`/`-y` fija el autoarranque, el inicio inmediato y la entrada en el menú de Aplicaciones en «sí» y el anonimato de red en «no» (salvo que una bandera concreta indique lo contrario) — la misma cautela sobre el anonimato explicada arriba para servidores remotos. Banderas individuales: `--[no-]autostart`, `--[no-]start-now`, `--[no-]privacy`, `--[no-]menu-entry`. Sin ninguna de ellas, la instalación sigue siendo interactiva como siempre, y no tiene efecto en el instalador gráfico (zenity).

VPN NetGuard necesita NetworkManager (`nmcli`) en cualquiera de los dos casos. Si tu servidor usa netplan con renderer `networkd` a secas, instálalo primero:

```bash
sudo apt install network-manager
sudo systemctl enable --now NetworkManager
```

Si falta cualquier otra dependencia (`iptables`, `ping`...), el propio script te dice exactamente qué falta y con qué paquete de `apt` instalarlo — no hace falta adivinar nada.

Una vez instalado, olvídate de `pkexec`/`sudo` para el uso diario: busca "VPN NetGuard" en el menú de Aplicaciones, o simplemente ejecuta `vpn-netguard.sh` sin argumentos para el menú de terminal. Cada acción que necesita privilegios los pide por separado, así que nunca hace falta abrir una terminal como root a propósito.

**Desinstalar:**

```bash
sudo bash vpn-netguard.sh uninstall
```

o la opción 19 del menú interactivo. Se conserva `/etc/vpn-netguard/vpn-netguard.conf` por si reinstalas más adelante; bórralo a mano (`sudo rm -rf /etc/vpn-netguard /var/lib/vpn-netguard`) si ya no lo necesitas.

**Alternativa opcional para lanzarlo:** si organizas tus scripts con [Scriptya](#scriptya), del mismo autor, puedes añadir `vpn-netguard.sh` a su menú y olvidarte también de recordar la ruta — más abajo se explica cómo.

## Comandos

| Comando | Qué hace |
|---|---|
| *(sin argumentos)* / `menu` | Abre el menú interactivo en la terminal |
| `install` | Instala VPN NetGuard en el sistema |
| `uninstall` | Desinstala VPN NetGuard del sistema |
| `panel` | Abre el panel de control gráfico (zenity) |
| `status` | Muestra el estado actual: interfaces, VPN, kill switch, DNS, anonimato... |
| `check` | Comprobación de salud con código de salida, pensada para cron/Nagios/Zabbix |
| `doctor` | Diagnóstico combinado: dependencias, red, firewall y kill switch |
| `activate` | Marca que quieres la VPN activa, conecta y activa la protección |
| `deactivate` | Marca que no la quieres activa y retira el bloqueo |
| `enable-killswitch` | Fuerza el bloqueo ahora mismo |
| `disable-killswitch` | Quita el bloqueo sin tocar si quieres la VPN activa |
| `apply-privacy` | (Re)aplica el módulo de anonimato de red (MAC, IPv6, hostname...) |
| `privacy-status` | Muestra el estado actual del anonimato de red |
| `export-config` | Exporta `vpn-netguard.conf` como copia de seguridad |
| `import-config` | Importa un `vpn-netguard.conf` exportado antes |
| `sync-localized` | Reescribe las unidades systemd/lanzador `.desktop` ya instalados con el idioma actual |
| `rotate-mac` | Regenera ya la MAC "stable" (lo usa el temporizador opcional) |
| `start` | Arranca el vigilante en primer plano (lo usa systemd, no hace falta a mano) |
| `boot-killswitch` | Bloqueo temprano antes de que exista red (lo usa systemd) |
| `version` / `--version` / `-v` | Muestra la versión instalada |
| `-h` / `--help` | Muestra esta misma ayuda por pantalla |

Casi todos requieren privilegios de root: usa `sudo`, `pkexec`, o déjaselo al servicio systemd, que ya se invoca a sí mismo correctamente. Las excepciones son el menú interactivo y el panel gráfico, que piden privilegios acción por acción según los vayas necesitando; `version`, que no los necesita en absoluto; y `export-config`, que solo lee el fichero de configuración.

## Uso diario

Lo habitual no necesita terminal, pero si la usas:

```bash
vpn-netguard.sh status      # qué hay conectado, si el kill switch está activo, DNS real...
vpn-netguard.sh activate    # conecta la VPN y activa la protección
vpn-netguard.sh deactivate  # desconecta y retira el bloqueo
vpn-netguard.sh panel       # el mismo panel gráfico, sin buscarlo en el menú de Aplicaciones
```

La diferencia entre `activate`/`deactivate` y `enable-killswitch`/`disable-killswitch` es lo primero que casi todo el mundo pregunta:

| Acción | Qué cambia | Cuándo usarla |
|---|---|---|
| `activate` / `deactivate` | Marca si **quieres** la VPN activa o no, y ajusta conexión y bloqueo en consecuencia | Uso normal, día a día |
| `enable-killswitch` / `disable-killswitch` | Fuerza o retira el bloqueo **sin** tocar si quieres la VPN activa | Depuración puntual, o probar el bloqueo sin desconectar nada |

Para monitorización desatendida, por ejemplo en un servidor:

```bash
vpn-netguard.sh check
```

Devuelve una línea de resumen y un código de salida (`0` = OK, `1` = aviso, `2` = crítico); si configuraste `PROMETHEUS_TEXTFILE_DIR`, también deja las métricas listas para node_exporter en esa misma llamada.

Y para ver qué está haciendo el servicio en tiempo real:

```bash
journalctl -u vpn-netguard.service -f
```

## Configuración

Toda la configuración vive en un único fichero, comentado línea por línea:

```
/etc/vpn-netguard/vpn-netguard.conf
```

Se genera con valores por defecto razonables al instalar, y no se sobrescribe en instalaciones posteriores. Algunas de las claves más relevantes:

```bash
LANGUAGE="es"                    # es | en — idioma de menús, panel y mensajes
KILLSWITCH_MODE="auto"          # auto | true | false
DNS_SERVERS="1.1.1.1 9.9.9.9"   # a qué DNS se permite salir mientras el kill switch bloquea
MAC_MODE="stable"                # stable | random | off
IPV6_PRIVACY="true"
PROMETHEUS_TEXTFILE_DIR=""       # vacío = desactivado
ALERT_HOOK=""                    # tu script o webhook, para servidores sin escritorio
```

Puedes editarlo a mano, desde el menú interactivo (opciones 8, 9 y 12) o el panel gráfico ("Configuración", "Anonimato de red" y "Monitorización"). Después de tocarlo, reinicia el servicio para que se aplique:

```bash
sudo systemctl restart vpn-netguard.service
```

## Compatibilidad

- **Objetivo principal:** Linux Mint 22.3 (Cinnamon), con panel gráfico y acceso directo en el menú de Aplicaciones.
- **También como servicio headless:** cualquier servidor Debian/Ubuntu con NetworkManager, sin entorno gráfico ni zenity — se instala y se usa igual por SSH, cambiando `pkexec` por `sudo`.
- **Requisitos:** Bash 4+, NetworkManager (`nmcli`), `iptables`, `systemd`. El resto (coreutils, `ping`, `flock`...) suele venir ya en el sistema base.

Opcionales — nada de esto es obligatorio, pero mejoran la experiencia:

| Paquete | Para qué |
|---|---|
| `ip6tables` | Kill switch también en IPv6 (muy recomendable) |
| `zenity` | Panel gráfico e instalador con ventanas |
| `wireguard-tools` (`wg`) | Detección de túnel zombie en conexiones WireGuard |
| `libnotify-bin` (`notify-send`) | Notificaciones de escritorio |
| `policykit-1` (`pkexec`) | Elevar privilegios sin terminal desde el panel/menú |

Debería funcionar sin cambios en cualquier derivado de Ubuntu/Debian con NetworkManager, aunque de momento solo está verificado en Linux Mint 22.3 Cinnamon y en un servidor Ubuntu/Debian headless. Convive bien con `ufw` (usa su propia cadena de `iptables`, independiente).

## Scriptya

VPN NetGuard no necesita nada más para funcionar. Si usas varios scripts propios, [Scriptya](https://github.com/filonux/Scriptya) —del mismo autor— es un menú que los organiza y puede convertir cualquiera de ellos en una app independiente con su propio icono.

Dejando `vpn-netguard.sh` en tu carpeta de scripts de Scriptya consigues un acceso directo para lanzarlo sin recordar la ruta. Eso sí: el "instalar" de Scriptya crea solo ese acceso directo. La instalación real de VPN NetGuard —los servicios systemd, el kill switch, el módulo de anonimato— sigue haciéndose una vez con `vpn-netguard.sh install`, como en la sección de arriba.

## Sobre el idioma

La interfaz es bilingüe: menú interactivo, panel gráfico, asistente de instalación y mensajes de estado están disponibles en español e inglés. Por defecto se usa español (`LANGUAGE="es"`); para cambiar a inglés, edita `LANGUAGE="en"` en `/etc/vpn-netguard/vpn-netguard.conf` (o hazlo desde la propia interfaz: opción 7 del menú, "Idioma de la interfaz" en el panel) y reinicia el servicio como en [Configuración](#configuración).

También puedes forzarlo puntualmente, sin tocar la configuración, con la variable de entorno `VPN_NETGUARD_LANGUAGE`:

```bash
VPN_NETGUARD_LANGUAGE=en vpn-netguard.sh status
```

Este README también está disponible en los dos idiomas — el enlace está arriba del todo, justo debajo de los badges.

**Mini hoja de ruta**, sujeta a que haya interés real:

- [x] Interfaz bilingüe (español/inglés): menú, panel y asistente de instalación
- [x] README bilingüe (español/inglés)
- [ ] Paquete `.deb` o repositorio `apt` propio, para instalar con `apt install` en vez de clonar el repositorio

Si te interesa, abre un issue — es la señal que necesito para priorizarlo.

## Contribuir

Los issues y pull requests son bienvenidos. Hay plantillas listas en `.github/` para reportar un fallo o proponer una mejora, y una guía completa en [CONTRIBUTING.md](.github/CONTRIBUTING.md).

## Seguridad

VPN NetGuard corre como root y modifica reglas de firewall. Si encuentras un problema de seguridad, repórtalo siguiendo el proceso de [SECURITY.md](.github/SECURITY.md) en vez de abrir un issue público.

## Licencia

Software libre bajo GNU General Public License versión 3 (GPLv3). Consulta el fichero [LICENSE.txt](LICENSE) para el texto completo.

---

<p align="center">Hecho por <strong><a href="https://github.com/filonux">Filonux</a></strong>.</p>
